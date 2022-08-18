# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_lists_test.rb
# @see https://redis.io/commands#list
class TestClusterCommandsOnLists < Minitest::Test
  include Helper::Cluster
  include Lint::Lists

  def test_lmove
    target_version "6.2" do
      assert_raises(Redis::CommandError) { super }
    end
  end

  def test_rpoplpush
    assert_raises(Redis::CommandError) { super }
  end
end
