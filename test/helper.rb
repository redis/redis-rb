$:.unshift File.expand_path('../lib', File.dirname(__FILE__))

require "test/unit"
require "logger"
require "stringio"

begin
  require "ruby-debug"
rescue LoadError
end

$VERBOSE = true

ENV["conn"] ||= "ruby"

require "redis"
require "redis/distributed"
require "redis/connection/#{ENV["conn"]}"

require 'redis/sentinel'

require "support/redis_mock"
require "support/connection/#{ENV["conn"]}"

PORT          = 6381
SENTINEL_PORT = 16381
SLAVE_1_PORT  = 6382
SLAVE_2_PORT  = 6383
OPTIONS       = {:port => PORT, :db => 15, :timeout => 0.1}
NODES         = ["redis://127.0.0.1:#{PORT}/15"]
SENTINELS     = ["redis://127.0.0.1:#{SENTINEL_PORT}"]
MASTER        = "redis://127.0.0.1:#{PORT}"
SLAVE_1       = "redis://127.0.0.1:#{SLAVE_1_PORT}"
SLAVE_2       = "redis://127.0.0.1:#{SLAVE_2_PORT}"

REDIS_DIR = File.dirname(__FILE__)
REDIS_CNF = File.join(REDIS_DIR, "test.conf")
REDIS_PID = File.join(REDIS_DIR, "db", "redis.pid")

REDIS_SLAVE_CNF = File.join(REDIS_DIR, "test_slave.conf")
REDIS_SLAVE_PID = File.join(REDIS_DIR, "db", "redis_slave.pid")

REDIS_SLAVE_2_CNF = File.join(REDIS_DIR, "test_slave2.conf")
REDIS_SLAVE_2_PID = File.join(REDIS_DIR, "db", "redis_slave2.pid")

REDIS_SENTINEL_CNF = File.join(REDIS_DIR, "test_sentinel.conf") + " --sentinel"
REDIS_SENTINEL_PID = File.join(REDIS_DIR, "db", "redis_sentinel.pid")

def init(redis)
  begin
    redis.select 14
    redis.flushdb
    redis.select 15
    redis.flushdb
    redis
  rescue Redis::CannotConnectError => e
    puts e
    puts <<-EOS

      Cannot connect to Redis.

      Make sure Redis is running on localhost, port #{PORT}.
      This testing suite connects to the database 15.

      To install redis:
        visit <http://redis.io/download/>.

      To start the server:
        rake start

      To stop the server:
        rake stop

    EOS
    exit 1
  end
end

def driver(*drivers, &blk)
  if drivers.map(&:to_s).include?(ENV["conn"])
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
    end

    def teardown
      @redis.quit if @redis
    end

    def redis_mock(commands, options = {}, &blk)
      RedisMock.start(commands) do |port|
        yield _new_client(options.merge(:port => port))
      end
    end

    def redis_mock_with_handler(handler, options = {}, &blk)
      RedisMock.start_with_handler(handler) do |port|
        yield _new_client(options.merge(:port => port))
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
      Redis.new(_format_options(options))
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
      Redis::Distributed.new(NODES, _format_options(options))
    end
  end

  module Sentinel
    include Generic

    def version
      Version.new(redis.info.first['redis_version'])
    end

    def setup
      puts 'sentinel setup'
      start_slave1
      start_slave2
      start_sentinel
      super
    end

    def teardown
      puts 'sentinel teardown'
      super
      stop_master
      stop_slave1
      stop_slave2
      stop_sentinel
      start_master
    end

    private

    def _format_options(options)
      {
          :timeout => OPTIONS[:timeout],
          :master_name => 'test',
          :logger => ::Logger.new(@log),
      }.merge(options)
    end

    def _new_client(options = {})
      Redis::Sentinel.new(SENTINELS, _format_options(options))
    end

    def start_master
      start_redis REDIS_CNF
    end

    def start_slave1
      start_redis REDIS_SLAVE_CNF
    end

    def start_slave2
      start_redis REDIS_SLAVE_2_CNF
    end

    def start_sentinel
      start_redis REDIS_SENTINEL_CNF
    end

    def stop_master
      stop_redis REDIS_PID
    end

    def stop_slave1
      stop_redis REDIS_SLAVE_1_PID
    end

    def stop_slave2
      stop_redis REDIS_SLAVE_2_PID
    end

    def stop_sentinel
      stop_redis REDIS_SENTINEL_PID
    end

    def stop_redis(pid)
      begin
        Process.kill "TERM", File.read(pid).to_i
        FileUtils.rm pid
      rescue
      end
    end

    def start_redis(conf)
      unless system("redis-server #{conf}")
        STDERR.puts "could not start redis-server with conf #{conf}"
        exit 1
      end
      sleep 1
    end
  end
end
