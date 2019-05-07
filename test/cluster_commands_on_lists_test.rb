# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/lists'

# ruby -w -Itest test/cluster_commands_on_lists_test.rb
# @see https://redis.io/commands#list
class TestClusterCommandsOnLists < Minitest::Test
  include Helper::Cluster
  include Lint::Lists

  def test_rpoplpush
    assert_raises(Redis::CommandError) { super }
  end
end
