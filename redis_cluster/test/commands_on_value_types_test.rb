# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_value_types_test.rb
class TestClusterCommandsOnValueTypes < Minitest::Test
  include Helper::Cluster
  include Lint::ValueTypes

  def test_move
    assert_raises(Redis::CommandError) { super }
  end

  def test_copy
    assert_raises(Redis::CommandError) { super }
  end
end
