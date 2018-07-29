# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_client_internals_test.rb
class TestClusterClientInternals < Test::Unit::TestCase
  include Helper::Cluster

  def test_handle_multiple_servers
    100.times { |i| redis.set(i.to_s, "hogehoge#{i}") }
    100.times { |i| assert_equal "hogehoge#{i}", redis.get(i.to_s) }
  end

  def test_info_of_cluster_mode_is_enabled
    assert_equal '1', redis.info['cluster_enabled']
  end

  def test_unknown_commands_does_not_work_by_default
    assert_raise(Redis::CommandError) do
      redis.not_yet_implemented_command('boo', 'foo')
    end
  end

  def test_with_reconnect
    assert_equal('Hello World', redis.with_reconnect { 'Hello World' })
  end

  def test_without_reconnect
    assert_equal('Hello World', redis.without_reconnect { 'Hello World' })
  end

  def test_connected?
    assert_equal true, redis.connected?
  end

  def test_close
    assert_equal true, redis.close
  end

  def test_disconnect!
    assert_equal true, redis.disconnect!
  end

  def test_asking
    assert_equal 'OK', redis.asking
  end

  def test_id
    expected = 'redis://127.0.0.1:7000/0 '\
               'redis://127.0.0.1:7001/0 '\
               'redis://127.0.0.1:7002/0'
    assert_equal expected, redis.id
  end

  def test_inspect
    expected = "#<Redis client v#{Redis::VERSION} for "\
               'redis://127.0.0.1:7000/0 '\
               'redis://127.0.0.1:7001/0 '\
               'redis://127.0.0.1:7002/0>'

    assert_equal expected, redis.inspect
  end

  def test_dup
    assert_instance_of Redis, redis.dup
  end

  def test_connection
    expected = [
      { host: '127.0.0.1', port: 7000, db: 0, id: 'redis://127.0.0.1:7000/0', location: '127.0.0.1:7000' },
      { host: '127.0.0.1', port: 7001, db: 0, id: 'redis://127.0.0.1:7001/0', location: '127.0.0.1:7001' },
      { host: '127.0.0.1', port: 7002, db: 0, id: 'redis://127.0.0.1:7002/0', location: '127.0.0.1:7002' }
    ]

    assert_equal expected, redis.connection
  end
end
