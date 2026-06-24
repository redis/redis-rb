# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_value_types_test.rb
class TestClusterCommandsOnValueTypes < Minitest::Test
  include Helper::Cluster
  include Lint::ValueTypes

  def test_move
    assert_raises(Redis::CommandError, 'ERR MOVE is not allowed in cluster mode') do
      redis.move("foo", 1)
    end
  end

  def test_copy
    redis.set("{key}1", "aaa")
    redis.copy("{key}1", "{key}2")
    assert_equal("aaa", redis.get("{key}2"))

    assert_raises(Redis::CommandError, 'ERR DB index is out of range') do
      redis.copy("{key}1", "{key}2", db: 1)
    end
  end
end
