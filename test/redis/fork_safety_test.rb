# frozen_string_literal: true

require "helper"

class TestForkSafety < Minitest::Test
  include Helper::Client

  def setup
    skip("Fork unavailable") unless Process.respond_to?(:fork)
  end

  def test_fork_safety
    redis = Redis.new(OPTIONS)
    redis.set "foo", 1

    child_pid = fork do
      # InheritedError triggers a reconnect,
      # so we need to disable reconnects to force
      # the exception bubble up
      redis.without_reconnect do
        redis.set "foo", 2
      end
      exit! 0
    rescue Redis::InheritedError
      exit! 127
    end

    _, status = Process.wait2(child_pid)

    assert_equal 127, status.exitstatus
    assert_equal "1", redis.get("foo")
  end

  def test_fork_safety_with_enabled_inherited_socket
    redis = Redis.new(OPTIONS.merge(inherit_socket: true))
    redis.set "foo", 1

    child_pid = fork do
      # InheritedError triggers a reconnect,
      # so we need to disable reconnects to force
      # the exception bubble up
      redis.without_reconnect do
        redis.set "foo", 2
      end
      exit! 0
    rescue Redis::InheritedError
      exit! 127
    end

    _, status = Process.wait2(child_pid)

    assert_equal 0, status.exitstatus
    assert_equal "2", redis.get("foo")
  end
end
