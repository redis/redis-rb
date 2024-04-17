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

    assert_empty(redis.multi {})

    assert_equal([1], redis.multi { |r| r.incr('counter') })
  end

  def test_unwatch
    assert_raises(Redis::Cluster::AmbiguousNodeError) do
      redis.unwatch
    end
  end

  def test_watch
    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.watch('{key}1', '{key}2')
    end

    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.watch('key1', 'key2') do |tx|
        tx.call('SET', 'key1', '1')
        tx.call('SET', 'key2', '2')
      end
    end

    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.watch('{hey}1', '{hey}2') do |tx|
        tx.call('SET', '{key}1', '1')
        tx.call('SET', '{key}2', '2')
      end
    end

    assert_empty(redis.watch('{key}1', '{key}2') {})

    redis.watch('{key}1', '{key}2') do |tx|
      tx.call('SET', '{key}1', '1')
      tx.call('SET', '{key}2', '2')
    end

    assert_equal %w[1 2], redis.mget('{key}1', '{key}2')
  end
end
