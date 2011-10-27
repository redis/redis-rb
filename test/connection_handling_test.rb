# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

setup do
  init Redis.new(OPTIONS)
end

test "AUTH" do
  replies = {
    :auth => lambda { |password| $auth = password; "+OK" },
    :get  => lambda { |key| $auth == "secret" ? "$3\r\nbar" : "$-1" },
  }

  redis_mock(replies) do
    redis = Redis.new(OPTIONS.merge(:port => 6380, :password => "secret"))

    assert "bar" == redis.get("foo")
  end
end

test "PING" do |r|
  assert "PONG" == r.ping
end

test "SELECT" do |r|
  r.set "foo", "bar"

  r.select 14
  assert nil == r.get("foo")

  r.client.disconnect

  assert nil == r.get("foo")
end

test "QUIT" do |r|
  r.quit

  assert !r.client.connected?
end

test "SHUTDOWN" do
  commands = {
    :shutdown => lambda { :exit }
  }

  redis_mock(commands) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    # SHUTDOWN does not reply: test that it does not raise here.
    assert nil == redis.shutdown
  end
end

test "SHUTDOWN with error" do
  connections = 0
  commands = {
    :select => lambda { |*_| connections += 1; "+OK\r\n" },
    :connections => lambda { ":#{connections}\r\n" },
    :shutdown => lambda { "-ERR could not shutdown\r\n" }
  }

  redis_mock(commands) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    connections = redis.connections

    # SHUTDOWN replies with an error: test that it gets raised
    assert_raise Redis::Error do
      redis.shutdown
    end

    # The connection should remain in tact
    assert connections == redis.connections
  end
end

test "SLAVEOF" do
  redis_mock(:slaveof => lambda { |host, port| "+SLAVEOF #{host} #{port}" }) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    assert "SLAVEOF localhost 6381" == redis.slaveof("localhost", 6381)
  end
end

test "BGREWRITEAOF" do
  redis_mock(:bgrewriteaof => lambda { "+BGREWRITEAOF" }) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    assert "BGREWRITEAOF" == redis.bgrewriteaof
  end
end

test "CONFIG GET" do |r|
  assert "300" == r.config(:get, "*")["timeout"]

  assert r.config(:get, "timeout") == { "timeout" => "300" }
end

test "CONFIG SET" do |r|
  begin
    assert "OK" == r.config(:set, "timeout", 200)
    assert "200" == r.config(:get, "*")["timeout"]

    assert "OK" == r.config(:set, "timeout", 100)
    assert "100" == r.config(:get, "*")["timeout"]
  ensure
    r.config :set, "timeout", 300
  end
end
