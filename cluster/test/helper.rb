# frozen_string_literal: true

require_relative "../../test/helper"
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require "redis-clustering"
require_relative 'support/orchestrator'

module Helper
  module Cluster
    include Generic

    DEFAULT_HOST = '127.0.0.1'
    DEFAULT_PORTS = (16_380..16_385).freeze

    ClusterSlotsRawReply = lambda { |host, port|
      # @see https://redis.io/topics/protocol
      <<-REPLY.delete(' ')
        *1\r
        *4\r
        :0\r
        :16383\r
        *3\r
        $#{host.size}\r
        #{host}\r
        :#{port}\r
        $40\r
        649fa246273043021a05f547a79478597d3f1dc5\r
        *3\r
        $#{host.size}\r
        #{host}\r
        :#{port}\r
        $40\r
        649fa246273043021a05f547a79478597d3f1dc5\r
      REPLY
    }

    ClusterNodesRawReply = lambda { |host, port|
      line = "649fa246273043021a05f547a79478597d3f1dc5 #{host}:#{port}@17000 "\
             'myself,master - 0 1530797742000 1 connected 0-16383'
      "$#{line.size}\r\n#{line}\r\n"
    }

    ClusterShardsRawReply = lambda { |host, port|
      <<-REPLY.delete(' ')
        *1\r
        *4\r
        $5\r
        slots\r
        *2\r
        :0\r
        :16383\r
        $5\r
        nodes\r
        *1\r
        *14\r
        $2\r
        id\r
        $40\r
        51a0020c166dab7f3f259b6cc46ce4ed4437fa1d\r
        $4\r
        port\r
        :#{port}\r
        $2\r
        ip\r
        $#{host.size}\r
        #{host}\r
        $8\r
        endpoint\r
        $#{host.size}\r
        #{host}\r
        $4\r
        role\r
        $6\r
        master\r
        $18\r
        replication-offset\r
        :967228\r
        $6\r
        health\r
        $6\r
        online\r
      REPLY
    }

    def init(redis)
      redis.flushall
      redis
    rescue Redis::CannotConnectError
      puts <<-MSG

        Cannot connect to Redis Cluster.

        Make sure Redis is running on localhost, port #{DEFAULT_PORTS}.

        Try this once:

          $ make stop_cluster

        Then run the build again:

          $ make

      MSG
      exit! 1
    end

    def build_another_client(options = {})
      client = _new_client(options)
      # Replica-aware bootstrap occasionally fails on a freshly created cluster because
      # replica nodes can briefly serve an incoherent CLUSTER SHARDS view. Pre-warm the
      # client so the test's first real command doesn't hit a transient InitialSetupError.
      warmup_cluster_client(client) if options[:replica]
      client
    end

    def warmup_cluster_client(client, max_attempts: 30, backoff: 0.1)
      attempts = 0
      begin
        client.ping
      rescue Redis::Cluster::InitialSetupError
        attempts += 1
        raise if attempts >= max_attempts

        sleep backoff
        retry
      end
    end

    def redis_cluster_mock(commands, options = {})
      host = DEFAULT_HOST
      port = nil

      cluster_subcommands = if commands.key?(:cluster)
        commands.delete(:cluster).transform_keys { |k| k.to_s.downcase }
      else
        {}
      end

      commands[:cluster] = lambda { |subcommand, *args|
        subcommand = subcommand.downcase
        if cluster_subcommands.key?(subcommand)
          cluster_subcommands[subcommand].call(*args)
        else
          case subcommand.downcase
          when 'slots' then ClusterSlotsRawReply.call(host, port)
          when 'nodes' then ClusterNodesRawReply.call(host, port)
          when 'shards' then ClusterShardsRawReply.call(host, port)
          else '+OK'
          end
        end
      }

      commands[:command] = ->(*_) { "*0\r\n" }

      RedisMock.start(commands, options) do |po|
        port = po
        scheme = options[:ssl] ? 'rediss' : 'redis'
        nodes = %W[#{scheme}://#{host}:#{port}]
        yield _new_client(options.merge(nodes: nodes))
      end
    end

    def redis_cluster_down
      trib = ClusterOrchestrator.new(_default_nodes, timeout: TIMEOUT)
      trib.down
      yield
    ensure
      trib.rebuild
      trib.close
    end

    def redis_cluster_failover
      trib = ClusterOrchestrator.new(_default_nodes, timeout: TIMEOUT)
      trib.failover
      yield
    ensure
      trib.rebuild
      trib.close
    end

    def redis_cluster_fail_master
      trib = ClusterOrchestrator.new(_default_nodes, timeout: TIMEOUT)
      trib.fail_serving_master
      yield
    ensure
      trib.restart_cluster_nodes
      trib.rebuild
      trib.close
    end

    # @param slot [Integer]
    # @param src [String] <ip>:<port>
    # @param dest [String] <ip>:<port>
    def redis_cluster_resharding(slot, src:, dest:)
      trib = ClusterOrchestrator.new(_default_nodes, timeout: TIMEOUT)
      trib.start_resharding(slot, src, dest)
      yield
      trib.finish_resharding(slot, dest)
    ensure
      trib.rebuild
      trib.close
    end

    private

    def _default_nodes(host: DEFAULT_HOST, ports: DEFAULT_PORTS)
      ports.map { |port| "redis://#{host}:#{port}" }
    end

    def _format_options(options)
      {
        timeout: OPTIONS[:timeout],
        nodes: _default_nodes
      }.merge(options)
    end

    def _new_client(options = {})
      Redis::Cluster.new(_format_options(options).merge(driver: ENV['DRIVER']))
    end

    # ACL commands are not propagated across cluster nodes by default, so applying
    # `ACL SETUSER` through the cluster client only creates the user on a single node.
    # Apply it on every primary and replica directly so the test client can authenticate
    # against any bootstrap node.
    def with_acl
      admins = DEFAULT_PORTS.map { |port| Redis.new(host: DEFAULT_HOST, port: port) }
      admins.each do |admin|
        admin.acl('SETUSER', 'johndoe', 'on',
                  '+ping', '+select', '+command', '+cluster|slots', '+cluster|nodes', '+cluster|shards',
                  '+readonly', '>mysecret')
      end
      yield('johndoe', 'mysecret')
    ensure
      admins&.each do |admin|
        admin.acl('DELUSER', 'johndoe')
        admin.close
      end
    end
  end
end
