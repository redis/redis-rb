# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

setup do
  log = StringIO.new

  [Redis.new(OPTIONS.merge(:logger => ::Logger.new(log))), log]
end

$TEST_PIPELINING = true

load File.expand_path("./lint/internals.rb", File.dirname(__FILE__))

test "provides a meaningful inspect" do |r, _|
  assert "#<Redis client v#{Redis::VERSION} connected to redis://127.0.0.1:6379/15 (Redis v#{r.info["redis_version"]})>" == r.inspect
end

test "Redis.current" do
  Redis.current.set("foo", "bar")

  assert "bar" == Redis.current.get("foo")

  Redis.current = Redis.new(OPTIONS.merge(:db => 14))

  assert Redis.current.get("foo").nil?
end
