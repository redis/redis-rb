# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_client_transactions_test.rb
class TestClusterClientTransactions < Test::Unit::TestCase
  include Helper::Cluster

  def test_transaction_with_hash_tag
    rc1 = redis
    rc2 = build_another_client

    rc1.multi do |cli|
      100.times { |i| cli.set("{key}#{i}", i) }
    end

    100.times { |i| assert_equal i.to_s, rc1.get("{key}#{i}") }
    100.times { |i| assert_equal i.to_s, rc2.get("{key}#{i}") }
  end

  def test_transaction_without_hash_tag
    rc1 = redis
    rc2 = build_another_client

    assert_raise(Redis::Cluster::CrossSlotPipeliningError) do
      rc1.multi do |cli|
        100.times { |i| cli.set("key#{i}", i) }
      end
    end

    100.times { |i| assert_equal nil, rc1.get("key#{i}") }
    100.times { |i| assert_equal nil, rc2.get("key#{i}") }
  end

  def test_transaction_with_replicas
    rc1 = build_another_client(replica: true)
    rc2 = build_another_client(replica: true)

    rc1.multi do |cli|
      100.times { |i| cli.set("{key}#{i}", i) }
    end

    sleep 0.1

    100.times { |i| assert_equal i.to_s, rc1.get("{key}#{i}") }
    100.times { |i| assert_equal i.to_s, rc2.get("{key}#{i}") }
  end

  def test_transaction_with_watch
    rc1 = redis
    rc2 = build_another_client

    rc1.set('{key}1', 100)
    rc1.watch('{key}1')

    rc2.set('{key}1', 200)
    val = rc1.get('{key}1').to_i
    val += 1

    rc1.multi do |cli|
      cli.set('{key}1', val)
      cli.set('{key}2', 300)
    end

    assert_equal '200', rc1.get('{key}1')
    assert_equal '200', rc2.get('{key}1')

    assert_equal nil, rc1.get('{key}2')
    assert_equal nil, rc2.get('{key}2')
  end
end
