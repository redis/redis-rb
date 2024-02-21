# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_transactions_test.rb
# @see https://redis.io/commands#transactions
class TestClusterCommandsOnTransactions < Minitest::Test
  include Helper::Cluster

  def test_discard
    assert_raises(Redis::Cluster::AmbiguousNodeError) do
      redis.discard
    end
  end

  def test_exec
    assert_raises(Redis::Cluster::AmbiguousNodeError) do
      redis.exec
    end
  end

  def test_multi
    assert_raises(LocalJumpError) do
      redis.multi
    end

    assert_raises(ArgumentError) do
      redis.multi {}
    end

    assert_equal([1], redis.multi { |r| r.incr('counter') })
  end

  def test_unwatch
    assert_raises(Redis::Cluster::AmbiguousNodeError) do
      redis.unwatch
    end
  end

  def test_watch
    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.watch('key1', 'key2') {}
    end
  end
end
