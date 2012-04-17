# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

test "Defaults" do
  config = Redis::Config.new

  assert "redis" == config[:scheme]
  assert "127.0.0.1" == config[:host]
  assert 6379 == config[:port]
  assert nil == config[:password]
  assert 0 == config[:db]
end

test "Configuration from hash" do
  config = Redis::Config.new \
    :host => "127.0.0.2",
    :port => 6380,
    :password => "pass",
    :db => 15

  assert "redis" == config[:scheme]
  assert "127.0.0.2" == config[:host]
  assert 6380 == config[:port]
  assert "pass" == config[:password]
  assert 15 == config[:db]
end

test "Configuration with unspecified parameter" do
  config = Redis::Config.new \
    :something => "somewhere"

  assert "somewhere" == config[:something]
end

test "Configuration from URL mixed with defaults" do
  config = Redis::Config.new \
    :url => "redis://127.0.0.2"

  assert "redis" == config[:scheme]
  assert "127.0.0.2" == config[:host]
  assert Redis::Config::DEFAULTS[:port] == config[:port]
  assert Redis::Config::DEFAULTS[:password] == config[:password]
  assert Redis::Config::DEFAULTS[:db] == config[:db]
end

test "TCP configuration from URL" do
  config = Redis::Config.new \
    :url => "redis://:pass@127.0.0.2:6380/15"

  assert "redis" == config[:scheme]
  assert "127.0.0.2" == config[:host]
  assert 6380 == config[:port]
  assert "pass" == config[:password]
  assert 15 == config[:db]
end

test "Unix configuration from URL" do
  config = Redis::Config.new \
    :url => "unix:///tmp/redis.sock"

  assert "unix" == config[:scheme]
  assert "/tmp/redis.sock" == config[:path]
  assert Redis::Config::DEFAULTS[:password] == config[:password]
  assert Redis::Config::DEFAULTS[:db] == config[:db]
end
