# encoding: UTF-8

require "helper"

class TestThreadSafety < Test::Unit::TestCase

  include Helper

  driver(:ruby, :hiredis) do
    def test_thread_safety
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
  end
end
