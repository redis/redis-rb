# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_client_internals_test.rb
class TestClusterClientInternals < Minitest::Test
  include Helper::Cluster

  def test_handle_multiple_servers
    100.times { |i| redis.set(i.to_s, "hogehoge#{i}") }
    100.times { |i| assert_equal "hogehoge#{i}", redis.get(i.to_s) }
  end

  def test_info_of_cluster_mode_is_enabled
    assert_equal '1', redis.info['cluster_enabled']
  end

  def test_unknown_commands_does_not_work_by_default
    assert_raises(Redis::CommandError) do
      redis.not_yet_implemented_command('boo', 'foo')
    end
  end

  def test_connected?
    assert_equal true, redis.connected?
  end

  def test_close
    redis.close
  end

  def test_disconnect!
    redis.disconnect!
  end

  def test_asking
    assert_equal 'OK', redis.asking
  end

  def test_id
    expected = '127.0.0.1:16380 '\
               '127.0.0.1:16381 '\
               '127.0.0.1:16382'
    assert_equal expected, redis.id
  end

  def test_inspect
    expected = "#<Redis client v#{Redis::VERSION} for "\
                  '127.0.0.1:16380 '\
                  '127.0.0.1:16381 '\
                  '127.0.0.1:16382>'

    assert_equal expected, redis.inspect
  end

  def test_acl_auth_success
    target_version "6.0.0" do
      with_acl do |username, password|
        nodes = DEFAULT_PORTS.map { |port| "redis://#{username}:#{password}@#{DEFAULT_HOST}:#{port}" }
        r = _new_client(nodes: nodes)
        assert_equal('PONG', r.ping)
      end
    end
  end

  def test_acl_auth_failure
    target_version "6.0.0" do
      with_acl do |username, _|
        assert_raises(Redis::Cluster::InitialSetupError) do
          nodes = DEFAULT_PORTS.map { |port| "redis://#{username}:wrongpassword@#{DEFAULT_HOST}:#{port}" }
          r = _new_client(nodes: nodes)
          r.ping
        end
      end
    end
  end
end
