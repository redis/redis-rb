# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

load './test/lint/hashes.rb'

test "HSETNX" do |r|
  r.hset("foo", "f1", "s1")
  r.hsetnx("foo", "f1", "s2")

  assert "s1" == r.hget("foo", "f1")

  r.del("foo")
  r.hsetnx("foo", "f1", "s2")

  assert "s2" == r.hget("foo", "f1")
end

test "HMGET" do |r|
  r.hset("foo", "f1", "s1")
  r.hset("foo", "f2", "s2")
  r.hset("foo", "f3", "s3")

  assert ["s2", "s3"] == r.hmget("foo", "f2", "f3")
end

test "HMGET mapped" do |r|
  r.hset("foo", "f1", "s1")
  r.hset("foo", "f2", "s2")
  r.hset("foo", "f3", "s3")

  assert({"f1" => "s1"} == r.mapped_hmget("foo", "f1"))
  assert({"f1" => "s1", "f2" => "s2"} == r.mapped_hmget("foo", "f1", "f2"))
end

test "Mapped HMSET" do |r|
  r.mapped_hmset("foo", :f1 => "s1", :f2 => "s2")

  assert "s1" == r.hget("foo", "f1")
  assert "s2" == r.hget("foo", "f2")
end

