# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

load './test/lint/hashes.rb'

test "Mapped HMGET in a pipeline returns plain array" do |r|
  r.hset("foo", "f1", "s1")
  r.hset("foo", "f2", "s2")

  result = r.pipelined do
    assert nil == r.mapped_hmget("foo", "f1", "f2")
  end

  assert result[0] == ["s1", "s2"]
end


test "HDEL" do |r|
  r.hmset( "foo", *["s1", "v1", "s2", "v2", "s3","v3"] )
  assert r.hdel( "foo", *["s1", "s2"] ) == 2
  assert r.hgetall("foo") == {"s3" => "v3"}
end

