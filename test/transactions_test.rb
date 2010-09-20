# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "MULTI/DISCARD" do |r|
  r.multi

  assert "QUEUED" == r.set("foo", "1")
  assert "QUEUED" == r.get("foo")

  r.discard

  assert nil == r.get("foo")
end

test "MULTI/EXEC with a block" do |r|
  r.multi do |r|
    r.set "foo", "s1"
  end

  assert "s1" == r.get("foo")

  begin
    r.multi do
      r.set "bar", "s2"
      raise "Some error"
      r.set "baz", "s3"
    end
  rescue
  end

  assert nil == r.get("bar")
  assert nil == r.get("baz")
end

test "MULTI/EXEC with a block operating on a wrong kind of key" do |r|
  begin
    r.multi do |r|
      r.set "foo", "s1"
      r.lpush "foo", "s2"
      r.get "foo"
    end
  rescue RuntimeError
  end

  assert "s1" == r.get("foo")
end

test "MULTI with a block yielding the client" do |r|
  r.multi do |multi|
    multi.set "foo", "s1"
  end

  assert "s1" == r.get("foo")
end

test "WATCH with an unmodified key" do |r|
  r.watch "foo"
  r.multi do |multi|
    multi.set "foo", "s1"
  end

  assert "s1" == r.get("foo")
end

test "WATCH with a modified key" do |r|
  r.watch "foo"
  r.set "foo", "s1"
  res = r.multi do |multi|
    multi.set "foo", "s2"
  end

  assert nil == res
  assert "s1" == r.get("foo")
end

test "UNWATCH with a modified key" do |r|
  r.watch "foo"
  r.set "foo", "s1"
  r.unwatch
  r.multi do |multi|
    multi.set "foo", "s2"
  end

  assert "s2" == r.get("foo")
end

