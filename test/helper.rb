require "test/unit"
require "logger"
require "stringio"
require "logger"
require "circuit_breaker"

$VERBOSE = false

ENV["DRIVER"] ||= "ruby"

require_relative "../lib/redis"
require_relative "../lib/redis/distributed"
require_relative "../lib/redis/connection/#{ENV["DRIVER"]}"

require_relative "support/redis_mock"
require_relative "support/connection/#{ENV["DRIVER"]}"

PORT    = 6381
OPTIONS = {:port => PORT, :db => 15, :timeout => Float(ENV["TIMEOUT"] || 0.1)}
NODES   = ["redis://127.0.0.1:#{PORT}/15"]

def init(redis)
  begin
    redis.select 14
    redis.flushdb
    redis.select 15
    redis.flushdb
    redis
  rescue Redis::CannotConnectError
    puts <<-EOS

      Cannot connect to Redis.

      Make sure Redis is running on localhost, port #{PORT}.
      This testing suite connects to the database 15.

      Try this once:

        $ make clean

      Then run the build again:

        $ make

    EOS
    exit 1
  end
end

def driver(*drivers, &blk)
  if drivers.map(&:to_s).include?(ENV["DRIVER"])
    class_eval(&blk)
  end
end

module Helper

  def run(runner)
    if respond_to?(:around)
      around { super(runner) }
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
    end

    def teardown
      @redis.quit if @redis
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
  end

  module Client

    include Generic

    def version
      Version.new(redis.info["redis_version"])
    end

    private

    def _format_options(options)
      OPTIONS.merge(:logger => ::Logger.new(@log)).merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(:driver => ENV["DRIVER"]))
    end
  end

  module Distributed

    include Generic

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
end
class RedisError < StandardError  
end  
class Redis
  def fails
    @client.fails
  end
end

class Redis
  class Client
    def fails
      raise RedisError, "redis error"
    end
    circuit_method :fails
    logger = Logger.new(STDOUT)
    logger.level = Logger::WARN
    circuit_handler do |handler|
      handler.logger = logger
      handler.failure_threshold = 10
      handler.failure_timeout = 10
      handler.invocation_timeout = 10
      handler.excluded_exceptions = [RuntimeError]
    end
  end
end