# frozen_string_literal: true

require "helper"

class TestForkSafety < Minitest::Test
  include Helper::Client

  driver(:ruby, :hiredis) do
    def test_fork_safety
      redis = Redis.new(OPTIONS)
      assert_equal "PONG", @redis.ping

      pid = fork do
        1000.times do
          assert_equal "OK", @redis.set("key", "foo")
        end
      end
      1000.times do
        assert_equal "PONG", @redis.ping
      end
      _, status = Process.wait2(pid)
      assert_predicate(status, :success?)
    rescue NotImplementedError => error
      raise unless error.message =~ /fork is not available/
    end

    def test_fork_safety_with_enabled_inherited_socket
      redis = Redis.new(OPTIONS.merge(inherit_socket: true))
      redis.set "foo", 1

      child_pid = fork do
        begin
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
      end

      _, status = Process.wait2(child_pid)

      assert_equal 0, status.exitstatus
      assert_equal "2", redis.get("foo")
    rescue NotImplementedError => error
      raise unless error.message =~ /fork is not available/
    end
  end
end
