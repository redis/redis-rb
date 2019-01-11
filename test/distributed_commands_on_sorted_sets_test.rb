require_relative 'helper'
require_relative 'lint/sorted_sets'

class TestDistributedCommandsOnSortedSets < Test::Unit::TestCase
  include Helper::Distributed
  include Lint::SortedSets

  def test_zinterstore
    assert_raise(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinterstore_with_aggregate
    assert_raise(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinterstore_with_weights
    assert_raise(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunionstore
    assert_raise(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunionstore_with_aggregate
    assert_raise(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunionstore_with_weights
    assert_raise(Redis::Distributed::CannotDistribute) { super }
  end
end
