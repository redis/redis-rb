# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestOperationNotPermitted < Test::Unit::TestCase

  include Helper::Client

  def test_includes_the_affected_command_in_the_error_message
    redis_mock(:set => lambda { |*_| "-ERR operation not permitted" }) do |redis|
      begin
        redis.set :foo, 1
      rescue Redis::CommandError => e
      end

      assert_match(/SET foo 1/, e.message)
    end
  end

  def test_pipeline_includes_the_first_affected_command_in_the_error_message
    redis_mock(:get => lambda { |*_| "-ERR operation not permitted" }) do |redis|
      begin
        redis.pipelined do
          redis.set :foo, 1
          redis.set :bar, 2
          redis.get :foo
          redis.set :baz, 3
        end
      rescue Redis::CommandError => e
      end

      assert_match(/GET foo/, e.message)
    end
  end

  def test_multi_with_block_includes_the_affected_commands_in_the_error_message
    commands = {
      :multi => lambda { |*_| "+OK" },
      :set   => lambda { |*_| "+QUEUED" },
      :get   => lambda { |*_| "-ERR operation not permitted" },
      :exec  => lambda { |*_| "-EXECABORT Transaction discarded because of previous errors." }
    }
    redis_mock(commands) do |redis|
      begin
        redis.multi do |multi|
          multi.set :foo, 1
          multi.set :bar, 2
          multi.get :foo
          multi.set :baz, 3
          multi.get :bar
        end
      rescue Redis::CommandError => e
      end

      assert_match(/GET foo/, e.message)
      assert_match(/GET bar/, e.message)
    end
  end

  def test_pubsub_includes_the_affected_command_in_the_error_message
    redis_mock(:subscribe => lambda { |*_| "-ERR operation not permitted" }) do |redis|
      begin
        redis.subscribe [:foo, :bar] do |on|
        end
      rescue Redis::CommandError => e
      end

      assert_match(/SUBSCRIBE foo bar/, e.message)
    end
  end

  def test_limit_the_error_message_length_to_avoid_long_strings
    items = (1..1000).to_a

    redis_mock(:set => lambda { |*_| "-ERR operation not permitted" }) do |redis|
      begin
        redis.set :foo, items
      rescue Redis::CommandError => e
      end

      assert_equal 256, e.message.size
    end
  end
end
