# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_client_transactions_test.rb
class TestClusterClientTransactions < Minitest::Test
  include Helper::Cluster

  def test_cluster_client_does_support_transaction_by_single_key
    actual = redis.multi do |tx|
      tx.set('counter', '0')
      tx.incr('counter')
      tx.incr('counter')
    end

    assert_equal(['OK', 1, 2], actual)
    assert_equal('2', redis.get('counter'))
  end

  def test_cluster_client_does_support_transaction_by_hashtag
    actual = redis.multi do |tx|
      tx.mset('{key}1', 1, '{key}2', 2)
      tx.mset('{key}3', 3, '{key}4', 4)
    end

    assert_equal(%w[OK OK], actual)
    assert_equal(%w[1 2 3 4], redis.mget('{key}1', '{key}2', '{key}3', '{key}4'))
  end

  def test_cluster_client_does_not_support_transaction_by_multiple_keys
    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.multi do |tx|
        tx.set('key1', 1)
        tx.set('key2', 2)
        tx.set('key3', 3)
        tx.set('key4', 4)
      end
    end

    assert_raises(Redis::Cluster::TransactionConsistencyError) do
      redis.multi do |tx|
        tx.mset('key1', 1, 'key2', 2)
        tx.mset('key3', 3, 'key4', 4)
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
      Fiber.yield
    end

    redis.watch('{key}1', '{key}2') do |client|
      another.resume
      v1 = client.get('{key}1')
      v2 = client.get('{key}2')

      client.multi do |tx|
        tx.set('{key}1', v2)
        tx.set('{key}2', v1)
      end
    end

    assert_equal %w[3 4], redis.mget('{key}1', '{key}2')
  end

  def test_cluster_client_can_be_used_compatible_with_standalone_client
    redis.set('{my}key', 'value')
    redis.set('{my}counter', '0')
    redis.watch('{my}key', '{my}counter') do |client|
      if client.get('{my}key') == 'value'
        client.multi do |tx|
          tx.set('{my}key', 'updated value')
          tx.incr('{my}counter')
        end
      else
        client.unwatch
      end
    end

    assert_equal('updated value', redis.get('{my}key'))
    assert_equal('1', redis.get('{my}counter'))

    another = Fiber.new do
      cli = build_another_client
      cli.set('{my}key', 'another value')
      cli.close
      Fiber.yield
    end

    redis.watch('{my}key', '{my}counter') do |client|
      another.resume
      if client.get('{my}key') == 'value'
        client.multi do |tx|
          tx.set('{my}key', 'latest value')
          tx.incr('{my}counter')
        end
      else
        client.unwatch
      end
    end

    assert_equal('another value', redis.get('{my}key'))
    assert_equal('1', redis.get('{my}counter'))
  end
end
