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

  def test_zlexcount
    # Not implemented yet
  end

  def test_zpopmax
    # Not implemented yet
  end

  def test_zpopmin
    # Not implemented yet
  end

  def test_zrangebylex
    # Not implemented yet
  end

  def test_zremrangebylex
    # Not implemented yet
  end

  def test_zrevrangebylex
    # Not implemented yet
  end

  def test_zscan
    # Not implemented yet
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
