# frozen_string_literal: true

require_relative '../errors'
require_relative '../client'
require_relative 'hash_ring'

class Redis
  class Distributed
    # Partitioning with client side consistent hashing
    class Partitioner
      def initialize(options = {})
        @options = options.dup
        @tag_fmt = @options.dig(:distributed, :tag) || /^\{(.+?)\}/
        @ring = @options.dig(:distributed, :ring) || HashRing.new
        node_configs = @options.dig(:distributed, :nodes)
        @options.delete(:distributed)
        clients = build_node_clients(node_configs, @options)
        clients.each { |c| @ring.add_node(c) }
        @command = build_command_info(@ring.nodes)
      end

      def id
        @ring.nodes.map(&:id).sort.join(', ')
      end

      def db
        @ring.nodes.first.db
      end

      def db=(_db)
        raise CannotDistribute, 'select'
      end

      def timeout
        @ring.nodes.first.timeout
      end

      def connected?
        @ring.nodes.any?(&:connected?)
      end

      def disconnect
        @ring.nodes.each(&:disconnect)
        true
      end

      def connection_info
        @ring.nodes.sort_by(&:id).map do |n|
          { host: n.host, port: n.port, db: n.db, id: n.id, location: n.location }
        end
      end

      def with_reconnect(val = true, &block)
        @ring.nodes.sample.with_reconnect(val, &block)
      end

      def call(command, &block)
        send_command(command, &block)
      end

      def call_loop(command, timeout = 0, &block)
        raise(CannotDistribute, 'monitor') if command.first.to_s.casecmp('monitor').zero?
        node_for(command).call_loop(command, timeout, &block)
      end

      def call_pipeline(pipeline)
        raise CannotDistribute, pipeline.commands.map(&:first).join(',')
      end

      def call_with_timeout(command, timeout, &block)
        node_for(command).call_with_timeout(command, timeout, &block)
      end

      def call_without_timeout(command, &block)
        call_with_timeout(command, 0, &block)
      end

      def process(commands, &block)
        if unsubscription_command?(commands)
          @ring.nodes.map { |n| n.process(commands, &block) }
        else
          node_for(commands.first).process(commands, &block)
        end
      end

      private

      def build_node_clients(node_configs, options)
        node_configs.map { |c| build_client(c, options) }
      end

      def build_client(config, options)
        config = config.is_a?(String) ? { url: config } : config
        Client.new(options.merge(config))
      end

      def build_command_info(nodes)
        details = {}

        nodes.each do |node|
          details = fetch_command_details(node)
          details.empty? ? next : break
        end

        details
      end

      def fetch_command_details(node)
        node.call(%i[command]).map do |reply|
          [reply[0], { arity: reply[1], flags: reply[2], first: reply[3], last: reply[4], step: reply[5] }]
        end.to_h
      rescue CannotConnectError, ConnectionError, CommandError
        {} # can retry on another node
      end

      def send_command(command, &block)
        case cmd = command.first.to_s.downcase
        when 'echo'   then send_command_each_node(command, &block).uniq
        when 'keys'   then send_command_each_node(command, &block).flatten
        when 'mget'   then send_mget_command(command, &block)
        when 'script' then send_script_command(command, &block)
        when 'auth', 'bgrewriteaof', 'bgsave', 'dbsize', 'flushall', 'flushdb',
             'info', 'lastsave', 'ping', 'quit', 'role', 'save', 'time', 'wait'
          send_command_each_node(command, &block)
        when 'client', 'cluster', 'config', 'discard', 'exec', 'memory',
             'migrate', 'multi', 'psubscribe', 'pubsub', 'randomkey',
             'readonly', 'readwrite', 'select', 'shutdown', 'unwatch', 'watch'
          raise CannotDistribute, cmd
        when 'node_for' then @ring.get_node(extract_tag_if_needed(command[1]))  # for backward compatibility
        when 'nodes'    then @ring.nodes                                        # for backward compatibility as possible
        when 'add_node' then @ring.add_node(build_client(command[1], @options)) # for backward compatibility
        else node_for(command).call(command, &block)
        end
      end

      def send_script_command(command, &block)
        case command[1].to_s.downcase
        when 'debug', 'kill', 'flush', 'load'
          send_command_each_node(command, &block)
        else node_for(command).call(command, &block)
        end
      end

      def send_command_each_node(command, &block)
        @ring.nodes.map { |node| node.call(command, &block) }
      end

      def send_mget_command(command)
        keys = extract_keys(command)
        vals = keys.map { |k| [k, @ring.get_node(extract_tag_if_needed(k))] }
                   .group_by { |_, node| node.id }
                   .map { |_, pairs| [pairs[0][1], pairs.map(&:first)] }
                   .map { |node, ks| ks.zip(node.call(%w[mget] + ks)).to_h }
                   .reduce(&:merge)
                   .values_at(*keys)
        block_given? ? yield(vals) : vals
      end

      def node_for(command)
        keys = extract_keys(command)
        return @ring.nodes.sample if keys.empty?

        assert_same_node!(keys)
        @ring.get_node(extract_tag_if_needed(keys.first))
      end

      def extract_keys(command)
        cmds = command.flatten.map(&:to_s).map { |s| s.valid_encoding? ? s.downcase : s }
        cmd = cmds.first
        info = @command[cmd]
        return [] if keyless_command?(cmd, info)

        last_pos = cmds.size - 1

        case cmd
        when 'publish' then [1]
        when 'subscribe' then (1..last_pos).to_a
        when 'memory' then cmds[1].casecmp('usage').zero? ? [2] : []
        when 'eval', 'evalsha' then (3..cmds[2].to_i + 2).to_a
        when 'psubscribe', 'pubsub', 'punsubscribe', 'unsubscribe', 'migrate' then []
        when 'sort'
          by = cmds.index('by')
          store = cmds.index('store')
          gets = cmds.map.with_index { |w, i| w == 'get' ? i + 1 : nil }
          [1, (by ? by + 1 : nil), (store ? store + 1 : nil), *gets].compact
        when 'zinterstore', 'zunionstore'
          last = cmds.index('weights') || cmds.index('aggregate') || last_pos + 1
          [1] + (3..last - 1).to_a
        when 'xread', 'xreadgroup'
          idx = cmds.index('streams')
          idx.nil? ? [] : (idx + 1..last_pos).to_a.slice(0, (last_pos - idx - 1) / 2 + 1)
        else
          last = info[:last] < 0 ? last_pos + info[:last] + 1 : info[:last]
          range = info[:first]..last
          (info[:step] < 1 ? range : range.step(info[:step])).to_a
        end.map { |i| cmds[i] }
      end

      def extract_tag_if_needed(key)
        key.to_s.slice(@tag_fmt, 1) || key
      end

      def assert_same_node!(keys)
        node_ids = keys.map { |k| @ring.get_node(extract_tag_if_needed(k)).id }.uniq
        raise(CannotDistribute, keys.join(',')) if node_ids.size > 1
      end

      def keyless_command?(cmd, info)
        info.nil? ||
          (info[:first] < 1 &&
           (info[:flags] & %w[pubsub movablekeys]).empty? &&
           (%w[memory] & [cmd]).empty?)
      end

      def unsubscription_command?(commands)
        commands.size == 1 &&
          %w[unsubscribe punsubscribe].include?(commands.first.first.to_s.downcase) &&
          commands.first.size == 1
      end
    end
  end
end
