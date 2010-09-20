# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "BULK commands" do |r|
  r.pipelined do
    r.lpush "foo", "s1"
    r.lpush "foo", "s2"
  end

  assert 2 == r.llen("foo")
  assert "s2" == r.lpop("foo")
  assert "s1" == r.lpop("foo")
end

test "MULTI_BULK commands" do |r|
  r.pipelined do
    r.mset("foo", "s1", "bar", "s2")
    r.mset("baz", "s3", "qux", "s4")
  end

  assert "s1" == r.get("foo")
  assert "s2" == r.get("bar")
  assert "s3" == r.get("baz")
  assert "s4" == r.get("qux")
end

test "BULK and MULTI_BULK commands mixed" do |r|
  r.pipelined do
    r.lpush "foo", "s1"
    r.lpush "foo", "s2"
    r.mset("baz", "s3", "qux", "s4")
  end

  assert 2 == r.llen("foo")
  assert "s2" == r.lpop("foo")
  assert "s1" == r.lpop("foo")
  assert "s3" == r.get("baz")
  assert "s4" == r.get("qux")
end

test "MULTI_BULK and BULK commands mixed" do |r|
  r.pipelined do
    r.mset("baz", "s3", "qux", "s4")
    r.lpush "foo", "s1"
    r.lpush "foo", "s2"
  end

  assert 2 == r.llen("foo")
  assert "s2" == r.lpop("foo")
  assert "s1" == r.lpop("foo")
  assert "s3" == r.get("baz")
  assert "s4" == r.get("qux")
end

test "Pipelined with an empty block" do |r|
  assert_nothing_raised do
    r.pipelined do
    end
  end

  assert 0 == r.dbsize
end

test "Returning the result of a pipeline" do |r|
  result = r.pipelined do
    r.set "foo", "bar"
    r.get "foo"
    r.get "bar"
  end

  assert ["OK", "bar", nil] == result
end

