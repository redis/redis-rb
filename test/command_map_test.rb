# encoding: UTF-8

require "helper"

class TestCommandMap < Test::Unit::TestCase

  include Helper

  def test_override_existing_commands
    r.set("counter", 1)

    assert 2 == r.incr("counter")

    r.client.command_map[:incr] = :decr

    assert 1 == r.incr("counter")
  end

  def test_override_non_existing_commands
    r.set("key", "value")

    assert_raise Redis::CommandError do
      r.idontexist("key")
    end

    r.client.command_map[:idontexist] = :get

    assert "value" == r.idontexist("key")
  end
end
