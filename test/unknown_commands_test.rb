# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestUnknownCommands < Test::Unit::TestCase

  include Helper::Client

  def test_should_try_to_work
    assert_raise Redis::CommandError do
      r.not_yet_implemented_command
    end
  end

  def test_multi_with_block_includes_unknown_commands_in_the_error_message
    begin
      redis.multi do |multi|
        multi.unknown1
        multi.unknown2
      end
    rescue => e
    end

    assert_match(/unknown1/, e.message)
    assert_match(/unknown2/, e.message)
  end
end
