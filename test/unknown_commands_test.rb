# encoding: UTF-8

require "helper"

class TestUnknownCommands < Test::Unit::TestCase

  include Helper::Client

  def test_should_try_to_work
    assert_raise RubyRedis::CommandError do
      r.not_yet_implemented_command
    end
  end
end
