# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_client_slots_test.rb
class TestClusterClientSlots < Test::Unit::TestCase
  include Helper::Cluster

  def test_slot_class
    slot = Redis::Cluster::Slot.new('127.0.0.1:7000' => 1..10)

    assert_equal false, slot.exists?(0)
    assert_equal true, slot.exists?(1)
    assert_equal true, slot.exists?(10)
    assert_equal false, slot.exists?(11)

    assert_equal nil, slot.find_node_key_of_master(0)
    assert_equal nil, slot.find_node_key_of_slave(0)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_master(1)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_slave(1)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_master(10)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_slave(10)
    assert_equal nil, slot.find_node_key_of_master(11)
    assert_equal nil, slot.find_node_key_of_slave(11)

    assert_equal nil, slot.put(1, '127.0.0.1:7001')
  end

  def test_slot_class_with_node_flags_and_replicas
    slot = Redis::Cluster::Slot.new({ '127.0.0.1:7000' => 1..10, '127.0.0.1:7001' => 1..10 },
                                    { '127.0.0.1:7000' => 'master', '127.0.0.1:7001' => 'slave' },
                                    true)

    assert_equal false, slot.exists?(0)
    assert_equal true, slot.exists?(1)
    assert_equal true, slot.exists?(10)
    assert_equal false, slot.exists?(11)

    assert_equal nil, slot.find_node_key_of_master(0)
    assert_equal nil, slot.find_node_key_of_slave(0)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_master(1)
    assert_equal '127.0.0.1:7001', slot.find_node_key_of_slave(1)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_master(10)
    assert_equal '127.0.0.1:7001', slot.find_node_key_of_slave(10)
    assert_equal nil, slot.find_node_key_of_master(11)
    assert_equal nil, slot.find_node_key_of_slave(11)

    assert_equal nil, slot.put(1, '127.0.0.1:7002')
  end

  def test_slot_class_with_node_flags_and_without_replicas
    slot = Redis::Cluster::Slot.new({ '127.0.0.1:7000' => 1..10, '127.0.0.1:7001' => 1..10 },
                                    { '127.0.0.1:7000' => 'master', '127.0.0.1:7001' => 'slave' },
                                    false)

    assert_equal false, slot.exists?(0)
    assert_equal true, slot.exists?(1)
    assert_equal true, slot.exists?(10)
    assert_equal false, slot.exists?(11)

    assert_equal nil, slot.find_node_key_of_master(0)
    assert_equal nil, slot.find_node_key_of_slave(0)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_master(1)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_slave(1)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_master(10)
    assert_equal '127.0.0.1:7000', slot.find_node_key_of_slave(10)
    assert_equal nil, slot.find_node_key_of_master(11)
    assert_equal nil, slot.find_node_key_of_slave(11)

    assert_equal nil, slot.put(1, '127.0.0.1:7002')
  end

  def test_slot_class_with_empty_slots
    slot = Redis::Cluster::Slot.new({})

    assert_equal false, slot.exists?(0)
    assert_equal false, slot.exists?(1)

    assert_equal nil, slot.find_node_key_of_master(0)
    assert_equal nil, slot.find_node_key_of_slave(0)
    assert_equal nil, slot.find_node_key_of_master(1)
    assert_equal nil, slot.find_node_key_of_slave(1)

    assert_equal nil, slot.put(1, '127.0.0.1:7001')
  end

  def test_redirection_when_slot_is_resharding
    100.times { |i| redis.set("{key}#{i}", i) }

    redis_cluster_resharding(12539, src: '127.0.0.1:7002', dest: '127.0.0.1:7000') do
      100.times { |i| assert_equal i.to_s, redis.get("{key}#{i}") }
    end
  end
end
