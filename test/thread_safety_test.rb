# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "thread safety" do
  next unless driver == :ruby || driver == :hiredis

  redis = Redis.connect(OPTIONS)

  redis.set "foo", 1
  redis.set "bar", 2

  sample = 100

  t1 = Thread.new do
    $foos = Array.new(sample) { redis.get "foo" }
  end

  t2 = Thread.new do
    $bars = Array.new(sample) { redis.get "bar" }
  end

  t1.join
  t2.join

  assert_equal ["1"], $foos.uniq
  assert_equal ["2"], $bars.uniq
end
