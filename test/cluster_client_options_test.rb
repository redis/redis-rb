# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_client_options_test.rb
class TestClusterClientOptions < Test::Unit::TestCase
  include Helper::Cluster

  def test_option_class
    option = Redis::Cluster::Option.new(cluster: %w[rediss://127.0.0.1:7000], replica: true)
    assert_equal({ '127.0.0.1:7000' => { url: 'rediss://127.0.0.1:7000' } }, option.per_node_key)
    assert_equal true, option.secure?
    assert_equal true, option.use_replica?

    option = Redis::Cluster::Option.new(cluster: %w[redis://127.0.0.1:7000], replica: false)
    assert_equal({ '127.0.0.1:7000' => { url: 'redis://127.0.0.1:7000' } }, option.per_node_key)
    assert_equal false, option.secure?
    assert_equal false, option.use_replica?

    option = Redis::Cluster::Option.new(cluster: %w[redis://127.0.0.1:7000])
    assert_equal({ '127.0.0.1:7000' => { url: 'redis://127.0.0.1:7000' } }, option.per_node_key)
    assert_equal false, option.secure?
    assert_equal false, option.use_replica?
  end

  def test_client_accepts_valid_node_configs
    nodes = ['redis://127.0.0.1:7000',
             'redis://127.0.0.1:7001',
             { host: '127.0.0.1', port: '7002' },
             { 'host' => '127.0.0.1', port: 7003 },
             'redis://127.0.0.1:7004',
             'redis://127.0.0.1:7005']

    assert_nothing_raised do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_accepts_valid_options
    assert_nothing_raised do
      build_another_client(timeout: 1.0)
    end
  end

  def test_client_ignores_invalid_options
    assert_nothing_raised do
      build_another_client(invalid_option: true)
    end
  end

  def test_client_works_even_if_so_many_unavailable_nodes_specified
    nodes = (6001..7005).map { |port| "redis://127.0.0.1:#{port}" }
    redis = build_another_client(cluster: nodes)

    assert_equal 'PONG', redis.ping
  end

  def test_client_does_not_accept_db_specified_url
    assert_raise(Redis::CannotConnectError, 'Could not connect to any nodes') do
      build_another_client(cluster: ['redis://127.0.0.1:7000/1/namespace'])
    end

    assert_raise(Redis::CannotConnectError, 'Could not connect to any nodes') do
      build_another_client(cluster: [{ host: '127.0.0.1', port: '7000' }], db: 1)
    end
  end

  def test_client_does_not_accept_unconnectable_node_url_only
    nodes = ['redis://127.0.0.1:7006']

    assert_raise(Redis::CannotConnectError, 'Could not connect to any nodes') do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_accepts_unconnectable_node_url_included
    nodes = ['redis://127.0.0.1:7000', 'redis://127.0.0.1:7006']

    assert_nothing_raised(Redis::CannotConnectError, 'Could not connect to any nodes') do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_http_scheme_url
    nodes = ['http://127.0.0.1:80']

    assert_raise(Redis::InvalidClientOptionError, "invalid uri scheme 'http'") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_blank_included_config
    nodes = ['']

    assert_raise(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_bool_included_config
    nodes = [true]

    assert_raise(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_nil_included_config
    nodes = [nil]

    assert_raise(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_array_included_config
    nodes = [[]]

    assert_raise(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_empty_hash_included_config
    nodes = [{}]

    assert_raise(Redis::InvalidClientOptionError, 'Redis option of `cluster` must includes `:host` and `:port` keys') do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_object_included_config
    nodes = [Object.new]

    assert_raise(Redis::InvalidClientOptionError, 'Redis Cluster node config must includes String or Hash') do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_not_array_config
    nodes = :not_array

    assert_raise(Redis::InvalidClientOptionError, 'Redis Cluster node config must be Array') do
      build_another_client(cluster: nodes)
    end
  end
end
