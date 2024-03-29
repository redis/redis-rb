# frozen_string_literal: true

require "helper"

class TestThreadSafety < Minitest::Test
  include Helper::Client

  def test_thread_safety
    redis = Redis.new(OPTIONS)
    redis.set "foo", 1
    redis.set "bar", 2

    sample = 100

    t1 = Thread.new do
      @foos = Array.new(sample) { redis.get "foo" }
    end

    t2 = Thread.new do
      @bars = Array.new(sample) { redis.get "bar" }
    end

    t1.join
    t2.join

    assert_equal ["1"], @foos.uniq
    assert_equal ["2"], @bars.uniq
  end
end
