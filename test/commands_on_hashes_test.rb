# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

load './test/lint/hashes.rb'

test "Mapped HMGET in a pipeline returns hash" do |r|
  r.hset("foo", "f1", "s1")
  r.hset("foo", "f2", "s2")

  result = r.pipelined do
    r.mapped_hmget("foo", "f1", "f2")
  end

  assert_equal result[0], { "f1" => "s1", "f2" => "s2" }
end
