# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/value_types'

# ruby -w -Itest test/cluster_commands_on_value_types_test.rb
class TestClusterCommandsOnValueTypes < Test::Unit::TestCase
  include Helper::Cluster
  include Lint::ValueTypes

  def test_move
    assert_raise(Redis::CommandError) { super }
  end
end
