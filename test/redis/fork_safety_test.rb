# frozen_string_literal: true

require "helper"

class TestForkSafety < Minitest::Test
  include Helper::Client

  def setup
    skip("Fork unavailable") unless Process.respond_to?(:fork)
  end

  def test_fork_safety
    redis = Redis.new(OPTIONS)
    pid = fork do
      1000.times do
        assert_equal "OK", redis.set("key", "foo")
      end
    end
    1000.times do
      assert_equal "PONG", redis.ping
    end
    _, status = Process.wait2(pid)
    assert_predicate(status, :success?)
  end
end
