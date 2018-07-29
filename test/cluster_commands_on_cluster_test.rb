# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_cluster_test.rb
# @see https://redis.io/commands#cluster
class TestClusterCommandsOnCluster < Test::Unit::TestCase
  include Helper::Cluster

  def test_cluster_addslots
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER ADDSLOTS command should be...') do
      redis.cluster(:addslots, 0, 1, 2)
    end
  end

  def test_cluster_count_failure_reports
    assert_raise(Redis::CommandError, 'ERR Unknown node unknown-node-id') do
      redis.cluster('count-failure-reports', 'unknown-node-id')
    end

    node_id = redis.cluster(:nodes).first.fetch('node_id')
    assert_true(redis.cluster('count-failure-reports', node_id) >= 0)
  end

  def test_cluster_countkeysinslot
    assert_true(redis.cluster(:countkeysinslot, 0) >= 0)
    assert_true(redis.cluster(:countkeysinslot, 16383) >= 0)

    assert_raise(Redis::CommandError, 'ERR Invalid slot') do
      redis.cluster(:countkeysinslot, -1)
    end

    assert_raise(Redis::CommandError, 'ERR Invalid slot') do
      redis.cluster(:countkeysinslot, 16384)
    end
  end

  def test_cluster_delslots
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER DELSLOTS command should be...') do
      redis.cluster(:delslots, 0, 1, 2)
    end
  end

  def test_cluster_failover
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER FAILOVER command should be...') do
      redis.cluster(:failover, 'FORCE')
    end
  end

  def test_cluster_forget
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER FORGET command should be...') do
      redis.cluster(:forget, 'unknown-node-id')
    end
  end

  def test_cluster_getkeysinslot
    assert_instance_of Array, redis.cluster(:getkeysinslot, 0, 3)
  end

  def test_cluster_info
    info = redis.cluster(:info)

    assert_equal '3', info.fetch('cluster_size')
  end

  def test_cluster_keyslot
    assert_equal Redis::Cluster::KeySlotConverter.convert('hogehoge'), redis.cluster(:keyslot, 'hogehoge')
    assert_equal Redis::Cluster::KeySlotConverter.convert('12345'), redis.cluster(:keyslot, '12345')
    assert_equal Redis::Cluster::KeySlotConverter.convert('foo'), redis.cluster(:keyslot, 'boo{foo}woo')
    assert_equal Redis::Cluster::KeySlotConverter.convert('antirez.is.cool'), redis.cluster(:keyslot, 'antirez.is.cool')
    assert_equal Redis::Cluster::KeySlotConverter.convert(''), redis.cluster(:keyslot, '')
  end

  def test_cluster_meet
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER MEET command should be...') do
      redis.cluster(:meet, '127.0.0.1', 11211)
    end
  end

  def test_cluster_nodes
    cluster_nodes = redis.cluster(:nodes)
    sample_node = cluster_nodes.first

    assert_equal 6, cluster_nodes.length
    assert_equal true, sample_node.key?('node_id')
    assert_equal true, sample_node.key?('ip_port')
    assert_equal true, sample_node.key?('flags')
    assert_equal true, sample_node.key?('master_node_id')
    assert_equal true, sample_node.key?('ping_sent')
    assert_equal true, sample_node.key?('pong_recv')
    assert_equal true, sample_node.key?('config_epoch')
    assert_equal true, sample_node.key?('link_state')
    assert_equal true, sample_node.key?('slots')
  end

  def test_cluster_replicate
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER REPLICATE command should be...') do
      redis.cluster(:replicate)
    end
  end

  def test_cluster_reset
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER RESET command should be...') do
      redis.cluster(:reset)
    end
  end

  def test_cluster_saveconfig
    assert_equal 'OK', redis.cluster(:saveconfig)
  end

  def test_cluster_set_config_epoch
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER SET-CONFIG-EPOCH command should be...') do
      redis.cluster('set-config-epoch')
    end
  end

  def test_cluster_setslot
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'CLUSTER SETSLOT command should be...') do
      redis.cluster(:setslot)
    end
  end

  def test_cluster_slaves
    cluster_nodes = redis.cluster(:nodes)

    sample_master_node_id = cluster_nodes.find { |n| n.fetch('master_node_id') == '-' }.fetch('node_id')
    sample_slave_node_id = cluster_nodes.find { |n| n.fetch('master_node_id') != '-' }.fetch('node_id')

    assert_equal 'slave', redis.cluster(:slaves, sample_master_node_id).first.fetch('flags').first
    assert_raise(Redis::CommandError, 'ERR The specified node is not a master') do
      redis.cluster(:slaves, sample_slave_node_id)
    end
  end

  def test_cluster_slots
    slots = redis.cluster(:slots)
    sample_slot = slots.first

    assert_equal 3, slots.length
    assert_equal true, sample_slot.key?('start_slot')
    assert_equal true, sample_slot.key?('end_slot')
    assert_equal true, sample_slot.key?('master')
    assert_equal true, sample_slot.fetch('master').key?('ip')
    assert_equal true, sample_slot.fetch('master').key?('port')
    assert_equal true, sample_slot.fetch('master').key?('node_id')
    assert_equal true, sample_slot.key?('replicas')
    assert_equal true, sample_slot.fetch('replicas').is_a?(Array)
    assert_equal true, sample_slot.fetch('replicas').first.key?('ip')
    assert_equal true, sample_slot.fetch('replicas').first.key?('port')
    assert_equal true, sample_slot.fetch('replicas').first.key?('node_id')
  end

  def test_readonly
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'READONLY command should be...') do
      redis.readonly
    end
  end

  def test_readwrite
    assert_raise(Redis::Cluster::OrchestrationCommandNotSupported, 'READWRITE command should be...') do
      redis.readwrite
    end
  end
end
