# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/sorted_sets'

# ruby -w -Itest test/cluster_commands_on_sorted_sets_test.rb
# @see https://redis.io/commands#sorted_set
class TestClusterCommandsOnSortedSets < Test::Unit::TestCase
  include Helper::Cluster
  include Lint::SortedSets

  def test_zinterstore
    assert_raise(Redis::CommandError) { super }
  end

  def test_zinterstore_with_aggregate
    assert_raise(Redis::CommandError) { super }
  end

  def test_zinterstore_with_weights
    assert_raise(Redis::CommandError) { super }
  end

  def test_zunionstore
    assert_raise(Redis::CommandError) { super }
  end

  def test_zunionstore_with_aggregate
    assert_raise(Redis::CommandError) { super }
  end

  def test_zunionstore_with_weights
    assert_raise(Redis::CommandError) { super }
  end
end
