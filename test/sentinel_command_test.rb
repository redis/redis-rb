# frozen_string_literal: true

require_relative 'helper'

# @see https://redis.io/topics/sentinel#sentinel-commands Sentinel commands
class SentinelCommandsTest < Minitest::Test
  include Helper::Sentinel

  def test_sentinel_command_master
    redis = build_sentinel_client
    result = redis.sentinel('master', MASTER_NAME)

    assert_equal result['name'], MASTER_NAME
    assert_equal result['ip'], LOCALHOST
  end

  def test_sentinel_command_masters
    redis = build_sentinel_client
    result = redis.sentinel('masters')

    assert_equal result[0]['name'], MASTER_NAME
    assert_equal result[0]['ip'], LOCALHOST
    assert_equal result[0]['port'], MASTER_PORT
  end

  def test_sentinel_command_slaves
    redis = build_sentinel_client
    result = redis.sentinel('slaves', MASTER_NAME)

    assert_equal result[0]['name'], "#{LOCALHOST}:#{SLAVE_PORT}"
    assert_equal result[0]['ip'], LOCALHOST
    assert_equal result[0]['port'], SLAVE_PORT
  end

  def test_sentinel_command_sentinels
    redis = build_sentinel_client
    result = redis.sentinel('sentinels', MASTER_NAME)

    assert_equal result[0]['ip'], LOCALHOST

    actual_ports = result.map { |r| r['port'] }.sort
    expected_ports = SENTINEL_PORTS[1..-1]
    assert_equal actual_ports, expected_ports
  end

  def test_sentinel_command_get_master_by_name
    redis = build_sentinel_client
    result = redis.sentinel('get-master-addr-by-name', MASTER_NAME)

    assert_equal result, [LOCALHOST, MASTER_PORT]
  end

  def test_sentinel_command_ckquorum
    redis = build_sentinel_client
    result = redis.sentinel('ckquorum', MASTER_NAME)

    assert_equal result, 'OK 3 usable Sentinels. Quorum and failover authorization can be reached'
  end
end
