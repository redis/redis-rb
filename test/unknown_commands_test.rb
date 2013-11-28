# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestUnknownCommands < Test::Unit::TestCase

  include Helper::Client

  def test_should_try_to_work
    assert_raise Redis::CommandError do
      r.not_yet_implemented_command
    end
  end

  def test_includes_the_command_in_the_error_description
    redis_mock(:set => lambda { |*_| "-ERR Operation not permitted" }) do |redis|
      begin
        redis.set("foo", 1)
      rescue Redis::CommandError => e
      end

      assert_includes e.message, "set foo 1"
    end
  end

  def test_strips_the_command_and_arguments_to_avoid_long_strings
    items = (1..1000).to_a

    redis_mock(:set => lambda { |*_| "-ERR Operation not permitted" }) do |redis|
      begin
        redis.set("foo", items)
      rescue Redis::CommandError => e
      end

      assert_equal 256, e.message.size
    end
  end
end
