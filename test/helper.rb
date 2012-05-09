$:.unshift File.expand_path('../lib', File.dirname(__FILE__))

require "test/unit"
require "logger"
require "stringio"

begin
  require "ruby-debug"
rescue LoadError
end

require "support/redis_mock"

PORT    = 6381
OPTIONS = {:port => PORT, :db => 15, :timeout => 0.1}
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

module Helper

  include RedisMock::Helper

  def self.included(base)
    base.extend(ClassMethods)
  end

  attr_reader :r

  def setup
    @r = init Redis.new(OPTIONS)
  end

  def run(runner)
    if respond_to?(:around)
      around { super(runner) }
    else
      super
    end
  end

  def version
    info = r.info
    info = info.first if info.kind_of?(Array)
    version_str_to_i info["redis_version"]
  end

  def version_str_to_i(str)
    str.split(".").map{ |v| v.ljust(2, '0') }.join.to_i
  end

  module ClassMethods

    def driver(*drivers, &blk)
      if drivers.map(&:to_s).include?(ENV["conn"])
        class_eval(&blk)
      end
    end
  end

  module Distributed

    attr_reader :log

    def setup
      @log = StringIO.new
      @r = init Redis::Distributed.new(NODES, :logger => ::Logger.new(log))
    end
  end
end

$VERBOSE = true

ENV["conn"] ||= "ruby"

require "redis/connection/#{ENV["conn"]}"
require "redis"
require "redis/distributed"

require "support/connection/#{ENV["conn"]}"

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
