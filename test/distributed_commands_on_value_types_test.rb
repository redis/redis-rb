# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require "redis/distributed"

setup do
  log = StringIO.new
  init(Redis::Distributed.new(NODES, :logger => ::Logger.new(log)))
end

load "./test/lint/value_types.rb"

test "DEL" do |r|
  r.set "foo", "s1"
  r.set "bar", "s2"
  r.set "baz", "s3"
  r.set "boo", "s4"
  r.set "bam", "s5"

  assert ["bam", "bar", "baz", "boo", "foo"] == r.keys("*").sort

  assert [1] == r.del("foo")

  assert ["bam", "bar", "baz", "boo"] == r.keys("*").sort

  assert [4] == r.del("bam", "bar", "baz", "boo")

  assert [] == r.keys("*").sort
end

test "RANDOMKEY" do |r|
  assert_raise Redis::Distributed::CannotDistribute do
    r.randomkey
  end
end

test "RENAME" do |r|
  assert_raise Redis::Distributed::CannotDistribute do
    r.set("foo", "s1")
    r.rename "foo", "bar"
  end

  assert "s1" == r.get("foo")
  assert nil == r.get("bar")
end

test "RENAMENX" do |r|
  assert_raise Redis::Distributed::CannotDistribute do
    r.set("foo", "s1")
    r.rename "foo", "bar"
  end

  assert "s1" == r.get("foo")
  assert nil  == r.get("bar")
end

test "DBSIZE" do |r|
  assert [0] == r.dbsize

  r.set("foo", "s1")

  assert [1] == r.dbsize
end

test "FLUSHDB" do |r|
  r.set("foo", "s1")
  r.set("bar", "s2")

  assert [2] == r.dbsize

  r.flushdb

  assert [0] == r.dbsize
end

