# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_client_transactions_test.rb
class TestClusterClientTransactions < Minitest::Test
  include Helper::Cluster

  def test_cluster_client_does_support_transaction_by_single_key
    actual = redis.multi do |r|
      r.set('counter', '0')
      r.incr('counter')
      r.incr('counter')
    end

    assert_equal(['OK', 1, 2], actual)
    assert_equal('2', redis.get('counter'))
  end

  def test_cluster_client_does_support_transaction_by_hashtag
    actual = redis.multi do |r|
      r.mset('{key}1', 1, '{key}2', 2)
      r.mset('{key}3', 3, '{key}4', 4)
    end

    assert_equal(%w[OK OK], actual)
    assert_equal(%w[1 2 3 4], redis.mget('{key}1', '{key}2', '{key}3', '{key}4'))
  end

  def test_cluster_client_does_not_support_transaction_by_multiple_keys
    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.multi do |r|
        r.set('key1', 1)
        r.set('key2', 2)
        r.set('key3', 3)
        r.set('key4', 4)
      end
    end

    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.multi do |r|
        r.mset('key1', 1, 'key2', 2)
        r.mset('key3', 3, 'key4', 4)
      end
    end

    (1..4).each do |i|
      assert_nil(redis.get("key#{i}"))
    end
  end

  def test_cluster_client_does_support_transaction_with_optimistic_locking
    redis.mset('{key}1', '1', '{key}2', '2')

    another = Fiber.new do
      cli = build_another_client
      cli.mset('{key}1', '3', '{key}2', '4')
      cli.close
    end

    redis.watch('{key}1', '{key}2') do
      another.resume
      v1 = redis.get('{key}1')
      v2 = redis.get('{key}2')
      redis.multi do |tx|
        tx.set('{key}1', v2)
        tx.set('{key}2', v1)
      end
    end

    assert_equal %w[3 4], redis.mget('{key}1', '{key}2')
  end

  def test_cluster_client_can_unwatch_transaction
    redis.set('key1', 'initial_value')

    another = Fiber.new do
      cli = build_another_client
      cli.set('key1', 'another_value')
    end

    redis.watch('key1') do
      another.resume
      redis.unwatch
    end
    # After calling unwatch, the same connection can be used to open a transaction which
    # isn't conditional and so will commit
    got = redis.multi do |tx|
      tx.set('key1', 'final_value')
    end

    assert_equal ['OK'], got
    assert_equal 'final_value', redis.get('key1')
  end

  def test_cluster_client_unwatches_on_exception
    redis.set('key1', 'initial_value')

    another = Fiber.new do
      cli = build_another_client
      cli.set('key1', 'another_value')
    end

    assert_raises(RuntimeError) do
      redis.watch('key1') do
        another.resume
        raise 'bang'
      end
    end
    # After catching the exception, the same connection can be used to open a transaction which
    # isn't conditional and so will commit
    # n.b. the actual behaviour which ensures this is actually in redis-cluster-client
    got = redis.multi do |tx|
      tx.set('key1', 'final_value')
    end

    assert_equal ['OK'], got
    assert_equal 'final_value', redis.get('key1')
  end
end
