# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

test "URL defaults to 127.0.0.1:6379" do
  redis = Redis.connect

  assert "127.0.0.1" == redis.client.host
  assert 6379 == redis.client.port
  assert 0 == redis.client.db
  assert nil == redis.client.password
end

test "allows to pass in a URL" do
  redis = Redis.connect :url => "redis://:secr3t@foo.com:999/2"

  assert "foo.com" == redis.client.host
  assert 999 == redis.client.port
  assert 2 == redis.client.db
  assert "secr3t" == redis.client.password
end

test "override URL if path option is passed" do
  redis = Redis.connect :url => "redis://:secr3t@foo.com/foo:999/2", :path => "/tmp/redis.sock"

  assert "/tmp/redis.sock" == redis.client.path
  assert nil == redis.client.host
  assert nil == redis.client.port
end

test "overrides URL if another connection option is passed" do
  redis = Redis.connect :url => "redis://:secr3t@foo.com:999/2", :port => 1000

  assert "foo.com" == redis.client.host
  assert 1000 == redis.client.port
  assert 2 == redis.client.db
  assert "secr3t" == redis.client.password
end

test "does not modify the passed options" do
  options = { :url => "redis://:secr3t@foo.com:999/2" }

  Redis.connect(options)

  assert({ :url => "redis://:secr3t@foo.com:999/2" } == options)
end

test "uses REDIS_URL over default if available" do
  ENV["REDIS_URL"] = "redis://:secr3t@foo.com:999/2"

  redis = Redis.connect

  assert "foo.com" == redis.client.host
  assert 999 == redis.client.port
  assert 2 == redis.client.db
  assert "secr3t" == redis.client.password

  ENV.delete("REDIS_URL")
end

test "allows specifying a unixsocket with url option" do
  redis = Redis.connect(:url => "unixsocket:///path/to/redis.socket")
  assert "/path/to/redis.socket" == redis.client.path
  assert nil == redis.client.port
  assert 0 == redis.client.db
  assert nil == redis.client.password

  ENV.delete("REDIS_URL")
end

test "allows specifying a unixsocket with database id with url option" do
  redis = Redis.connect(:url => "unixsocket:///path/to/redis.socket:4")
  assert "/path/to/redis.socket" == redis.client.path
  assert nil == redis.client.port
  assert 4 == redis.client.db
  assert nil == redis.client.password

  ENV.delete("REDIS_URL")
end

test "allows specifying a unixsocket in REDIS_URL" do
  ENV["REDIS_URL"] = "unixsocket:///path/to/redis.socket"
  redis = Redis.connect
  assert "/path/to/redis.socket" == redis.client.path
  assert nil == redis.client.port
  assert 0 == redis.client.db
  assert nil == redis.client.password

  ENV.delete("REDIS_URL")
end

test "allows specifying a unixsocket with database id in REDIS_URL" do
  ENV["REDIS_URL"] = "unixsocket:///path/to/redis.socket:3"
  redis = Redis.connect
  assert "/path/to/redis.socket" == redis.client.path
  assert nil == redis.client.port
  assert 3 == redis.client.db
  assert nil == redis.client.password

  ENV.delete("REDIS_URL")
end

test "does not overwrite path from options with url" do
  redis = Redis.connect(:url => "unixsocket:///path/to/redis.socket:3", :path => "/path/to/socket/from/path.socket", :db => 7)
  assert "/path/to/socket/from/path.socket" == redis.client.path
  assert nil == redis.client.port
  assert 7 == redis.client.db
  assert nil == redis.client.password
end

test "does not overwrite path from options with url without db" do
  redis = Redis.connect(:url => "unixsocket:///path/to/redis.socket", :path => "/path/to/socket/from/path.socket", :db => 6)
  assert "/path/to/socket/from/path.socket" == redis.client.path
  assert nil == redis.client.port
  assert 6 == redis.client.db
  assert nil == redis.client.password
end
