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

  def test_resp3_unsupported_detects_initial_setup_error_from_old_nodes
    # When cluster nodes don't speak RESP3, the per-node HELLO failures are wrapped into an
    # InitialSetupError that discards the original classes; resp3_unsupported? must still recognize
    # it (by message) so Redis#send_command can fall back to RESP2 for pre-6.0 clusters.
    no_hello = RedisClient::UnsupportedServer.new(
      "redis-client requires Redis 6+ with HELLO command available (redis://127.0.0.1:16380)"
    )
    noproto = RedisClient::CommandError.new("NOPROTO unsupported protocol version")

    assert Redis::Client.resp3_unsupported?(RedisClient::Cluster::InitialSetupError.from_errors([no_hello]))
    assert Redis::Client.resp3_unsupported?(RedisClient::Cluster::InitialSetupError.from_errors([noproto]))
  end

  def test_resp3_unsupported_ignores_unrelated_initial_setup_error
    # A topology failure for other reasons (e.g. auth/connectivity) must NOT trigger the fallback.
    other = RedisClient::CommandError.new("WRONGPASS invalid username-password pair")
    refute Redis::Client.resp3_unsupported?(RedisClient::Cluster::InitialSetupError.from_errors([other]))
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

  # `CLIENT INFO` replies as one space-separated line of `key=value` pairs. Parsing it into fields
  # keeps the assertions exact: `assert_includes info, "lib-name=redis-rb"` would also accept
  # `lib-name=redis-rb-<version>`.
  def client_info_fields(client)
    client.client(:info).split(" ").to_h { |field| field.split("=", 2) }
  end

  def test_lib_name_set_via_client_setinfo
    target_version "7.2.0" do
      redis.ping
      fields = client_info_fields(redis)

      assert_equal "redis-rb", fields["lib-name"]
      assert_equal Redis::VERSION, fields["lib-ver"]
    end
  end

  def test_lib_name_includes_downstream_driver_info
    # Pins that `driver_info:` is threaded in a way a caller cannot replace, which is a separate
    # code path in Redis::Cluster#initialize_client from the standalone client.
    target_version "7.2.0" do
      client = _new_client(driver_info: "my-gem-1.0")
      client.ping
      fields = client_info_fields(client)

      assert_equal "redis-rb(my-gem-1.0)", fields["lib-name"]
      assert_equal Redis::VERSION, fields["lib-ver"]
    end
  end
end
