# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "multi HGETALL" do |r|
  r.hmset("foo", "f1", "s1", "f2", "s2")

  multi_response = r.multi do
    r.hgetall("foo")
  end

  assert multi_response[0] == ["f1", "s1", "f2", "s2"]
end

test "multi mapped HMGET" do |r|
  r.hmset("foo", "f1", "s1", "f2", "s2")

  multi_response = r.multi do
    r.mapped_hmget("foo", "f1", "f2")
  end

  assert multi_response[0] == ["s1", "s2"]
end

test "multi mapped MGET" do |r|
  r.set("foo", "s1")
  r.set("bar", "s2")

  multi_response = r.multi do
    r.mapped_mget("foo", "bar")
  end

  assert multi_response[0] == ["s1", "s2"]
end
