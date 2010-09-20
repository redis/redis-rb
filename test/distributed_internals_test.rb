# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

require "redis/distributed"

setup do
  log = StringIO.new
  [init(Redis::Distributed.new(NODES, :logger => ::Logger.new(log))), log]
end

$TEST_PIPELINING = false
$TEST_INSPECT    = false

load File.expand_path("./lint/internals.rb", File.dirname(__FILE__))
