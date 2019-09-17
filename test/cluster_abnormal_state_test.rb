# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_abnormal_state_test.rb
class TestClusterAbnormalState < Minitest::Test
  include Helper::Cluster

  def test_the_state_of_cluster_down
    redis_cluster_down do
      assert_raises(Redis::CommandError, 'CLUSTERDOWN Hash slot not served') do
        redis.set('key1', 1)
      end

      assert_equal 'fail', redis.cluster(:info).fetch('cluster_state')
    end
  end

  def test_the_state_of_cluster_failover
    redis_cluster_failover do
      10.times do |i|
        assert_equal 'OK', r.set("key#{i}", i)
      end

      10.times do |i|
        assert_equal i.to_s, r.get("key#{i}")
      end

      assert_equal 'ok', redis.cluster(:info).fetch('cluster_state')
    end
  end

  def test_the_state_of_cluster_node_failure
    redis_cluster_fail_master do
      assert_raises(Redis::CannotConnectError, 'Error connecting to Redis on 127.0.0.1:7002') do
        r.set('key0', 0)
      end

      10.times do |i|
        assert_equal 'OK', r.set("key#{i}", i)
      end

      10.times do |i|
        assert_equal i.to_s, r.get("key#{i}")
      end

      assert_equal 'ok', redis.cluster(:info).fetch('cluster_state')
    end
  end

  def test_raising_error_when_nodes_are_not_cluster_mode
    assert_raises(Redis::CannotConnectError, 'Redis client could not connect to any cluster nodes') do
      build_another_client(cluster: %W[redis://127.0.0.1:#{PORT}])
    end
  end
end
