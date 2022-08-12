# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnSortedSets < Minitest::Test
  include Helper::Distributed
  include Lint::SortedSets

  def test_zrangestore
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinter
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinter_with_aggregate
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinter_with_weights
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinterstore
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinterstore_with_aggregate
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zinterstore_with_weights
    assert_raises(Redis::Distributed::CannotDistribute) { super }
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

  def test_zunion
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunion_with_aggregate
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunion_with_weights
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunionstore
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunionstore_with_aggregate
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zunionstore_with_weights
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zdiff
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end

  def test_zdiffstore
    assert_raises(Redis::Distributed::CannotDistribute) { super }
  end
end
