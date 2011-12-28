# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require "redis/distributed"

setup do
  log = StringIO.new
  init Redis::Distributed.new(NODES, :logger => ::Logger.new(log))
end

load './test/lint/sorted_sets.rb'

test "ZCOUNT" do |r|
  r.zadd "foo", 1, "s1"
  r.zadd "foo", 2, "s2"
  r.zadd "foo", 3, "s3"

  assert 2 == r.zcount("foo", 2, 3)
end
