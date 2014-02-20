# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestForkSafety < Test::Unit::TestCase

  include Helper::Client

  driver(:ruby, :hiredis) do
    def test_fork_safety
      redis = Redis.new(OPTIONS)
      redis.set "foo", 1

      child_pid = fork {
        begin
          # InheritedError triggers a reconnect,
          # so we need to disable reconnects to force
          # the exception bubble up
          redis.without_reconnect {
            redis.set "foo", 2
          }
        rescue Redis::InheritedError
          exit 127
        end
      }

      _, status = Process.wait2(child_pid)

      assert_equal 127, status.exitstatus
      assert_equal "1", redis.get("foo")

    end
  end
end
