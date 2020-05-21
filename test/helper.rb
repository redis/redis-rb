# frozen_string_literal: true

require "minitest/autorun"
require "mocha/minitest"
require "logger"
require "stringio"

$VERBOSE = true

ENV["DRIVER"] ||= "ruby"

require_relative "../lib/redis"
require_relative "../lib/redis/distributed"
require_relative "../lib/redis/connection/#{ENV["DRIVER"]}"

require_relative "support/redis_mock"
require_relative "support/connection/#{ENV["DRIVER"]}"
require_relative 'support/cluster/orchestrator'

PORT        = 6381
DB          = 15
TIMEOUT     = Float(ENV['TIMEOUT'] || 1.0)
LOW_TIMEOUT = Float(ENV['LOW_TIMEOUT'] || 0.01) # for blocking-command tests
OPTIONS     = { port: PORT, db: DB, timeout: TIMEOUT }.freeze

def driver(*drivers, &blk)
  if drivers.map(&:to_s).include?(ENV["DRIVER"])
    class_eval(&blk)
  end
end

module Helper

  def run
    if respond_to?(:around)
      around { super }
    else
      super
    end
  end

  def silent
    verbose, $VERBOSE = $VERBOSE, false

    begin
      yield
    ensure
      $VERBOSE = verbose
    end
  end

  def with_external_encoding(encoding)
    original_encoding = Encoding.default_external

    begin
      silent { Encoding.default_external = Encoding.find(encoding) }
      yield
    ensure
      silent { Encoding.default_external = original_encoding }
    end
  end

  class Version

    include Comparable

    attr :parts

    def initialize(v)
      case v
      when Version
        @parts = v.parts
      else
        @parts = v.to_s.split(".")
      end
    end

    def <=>(other)
      other = Version.new(other)
      length = [self.parts.length, other.parts.length].max
      length.times do |i|
        a, b = self.parts[i], other.parts[i]

        return -1 if a.nil?
        return +1 if b.nil?
        return a.to_i <=> b.to_i if a != b
      end

      0
    end
  end

  module Generic

    include Helper

    attr_reader :log
    attr_reader :redis

    alias :r :redis

    def setup
      @log = StringIO.new
      @redis = init _new_client

      # Run GC to make sure orphaned connections are closed.
      GC.start
      super
    end

    def teardown
      redis.quit if redis
      super
    end

    def init(redis)
      redis.select 14
      redis.flushdb
      redis.select 15
      redis.flushdb
      redis
    rescue Redis::CannotConnectError
      puts <<-MSG

        Cannot connect to Redis.

        Make sure Redis is running on localhost, port #{PORT}.
        This testing suite connects to the database 15.

        Try this once:

          $ make clean

        Then run the build again:

          $ make

      MSG
      exit 1
    end

    def redis_mock(commands, options = {}, &blk)
      RedisMock.start(commands, options) do |port|
        yield _new_client(options.merge(:port => port))
      end
    end

    def redis_mock_with_handler(handler, options = {}, &blk)
      RedisMock.start_with_handler(handler, options) do |port|
        yield _new_client(options.merge(:port => port))
      end
    end

    def assert_in_range(range, value)
      assert range.include?(value), "expected #{value} to be in #{range.inspect}"
    end

    def target_version(target)
      if version < target
        skip("Requires Redis > #{target}") if respond_to?(:skip)
      else
        yield
      end
    end

    def omit_version(min_ver)
      skip("Requires Redis > #{min_ver}") if version < min_ver
    end

    def version
      Version.new(redis.info['redis_version'])
    end
  end

  module Client
    include Generic

    def new_client(options = {})
      _new_client(options)
    end

    private

    def _format_options(options)
      OPTIONS.merge(:logger => ::Logger.new(@log)).merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(:driver => ENV["DRIVER"]))
    end
  end

  module Sentinel
    include Generic

    MASTER_PORT = PORT.to_s
    SLAVE_PORT = '6382'
    SENTINEL_PORT = '6400'
    SENTINEL_PORTS = %w[6400 6401 6402].freeze
    MASTER_NAME = 'master1'
    LOCALHOST = '127.0.0.1'

    def build_sentinel_client(options = {})
      opts = { host: LOCALHOST, port: SENTINEL_PORT, timeout: TIMEOUT, logger: ::Logger.new(@log) }
      Redis.new(opts.merge(options))
    end

    def build_slave_role_client(options = {})
      _new_client(options.merge(role: :slave))
    end

    private

    def _format_options(options = {})
      {
        url: "redis://#{MASTER_NAME}",
        sentinels: [{ host: LOCALHOST, port: SENTINEL_PORT }],
        role: :master, timeout: TIMEOUT, logger: ::Logger.new(@log)
      }.merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(driver: ENV['DRIVER']))
    end
  end

  module Distributed
    include Generic

    NODES = ["redis://127.0.0.1:#{PORT}/#{DB}"].freeze

    def version
      Version.new(redis.info.first["redis_version"])
    end

    private

    def _format_options(options)
      {
        :timeout => OPTIONS[:timeout],
        :logger => ::Logger.new(@log),
      }.merge(options)
    end

    def _new_client(options = {})
      Redis::Distributed.new(NODES, _format_options(options).merge(:driver => ENV["conn"]))
    end
  end

  module Cluster
    include Generic

    DEFAULT_HOST = '127.0.0.1'
    DEFAULT_PORTS = (7000..7005).freeze

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
      _new_client(options)
    end

    def redis_cluster_mock(commands, options = {})
      host = DEFAULT_HOST
      port = nil

      cluster_subcommands = if commands.key?(:cluster)
                              commands.delete(:cluster)
                                      .map { |k, v| [k.to_s.downcase, v] }
                                      .to_h
                            else
                              {}
                            end

      commands[:cluster] = lambda { |subcommand, *args|
        if cluster_subcommands.key?(subcommand)
          cluster_subcommands[subcommand].call(*args)
        else
          case subcommand
          when 'slots' then ClusterSlotsRawReply.call(host, port)
          when 'nodes' then ClusterNodesRawReply.call(host, port)
          else '+OK'
          end
        end
      }

      commands[:command] = ->(*_) { "*0\r\n" }

      RedisMock.start(commands, options) do |po|
        port = po
        scheme = options[:ssl] ? 'rediss' : 'redis'
        nodes = %W[#{scheme}://#{host}:#{port}]
        yield _new_client(options.merge(cluster: nodes))
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
        logger: ::Logger.new(@log),
        cluster: _default_nodes
      }.merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(driver: ENV['DRIVER']))
    end
  end
end
