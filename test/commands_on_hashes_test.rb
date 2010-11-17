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
