require_relative "helper"

class TestCommandMap < Test::Unit::TestCase

  include Helper::Client

  def test_override_existing_commands
    r.set("counter", 1)

    assert_equal 2, r.incr("counter")

    r._client.command_map[:incr] = :decr

    assert_equal 1, r.incr("counter")
  end

  def test_override_non_existing_commands
    r.set("key", "value")

    assert_raise Redis::CommandError do
      r.idontexist("key")
    end

    r._client.command_map[:idontexist] = :get

    assert_equal "value", r.idontexist("key")
  end
end
