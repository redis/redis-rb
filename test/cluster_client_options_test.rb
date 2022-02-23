# frozen_string_literal: true

require 'uri'
require 'helper'

# ruby -w -Itest test/cluster_client_options_test.rb
class TestClusterClientOptions < Minitest::Test
  include Helper::Cluster

  def test_option_class
    option = Redis::Cluster::Option.new(cluster: %w[redis://127.0.0.1:7000], replica: true)
    assert_equal({ '127.0.0.1:7000' => { ssl: false, host: '127.0.0.1', port: 7000 } }, option.per_node_key)
    assert_equal true, option.use_replica?

    option = Redis::Cluster::Option.new(cluster: %w[redis://127.0.0.1:7000], replica: false)
    assert_equal({ '127.0.0.1:7000' => { ssl: false, host: '127.0.0.1', port: 7000 } }, option.per_node_key)
    assert_equal false, option.use_replica?

    option = Redis::Cluster::Option.new(cluster: %w[redis://127.0.0.1:7000])
    assert_equal({ '127.0.0.1:7000' => { ssl: false, host: '127.0.0.1', port: 7000 } }, option.per_node_key)
    assert_equal false, option.use_replica?

    option = Redis::Cluster::Option.new(cluster: %w[rediss://johndoe:foobar@127.0.0.1:7000/1/namespace])
    assert_equal({ '127.0.0.1:7000' => { ssl: true, username: 'johndoe', password: 'foobar', host: '127.0.0.1', port: 7000, db: 1 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: %w[rediss://127.0.0.1:7000], ssl: false)
    assert_equal({ '127.0.0.1:7000' => { ssl: true, host: '127.0.0.1', port: 7000 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: %w[redis://bazzap:@127.0.0.1:7000], username: 'foobar')
    assert_equal({ '127.0.0.1:7000' => { ssl: false, username: 'bazzap', host: '127.0.0.1', port: 7000 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: %w[redis://:bazzap@127.0.0.1:7000], password: 'foobar')
    assert_equal({ '127.0.0.1:7000' => { ssl: false, password: 'bazzap', host: '127.0.0.1', port: 7000 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: %W[redis://#{URI.encode_www_form_component('!&<123-abc>')}:@127.0.0.1:7000])
    assert_equal({ '127.0.0.1:7000' => { ssl: false, username: '!&<123-abc>', host: '127.0.0.1', port: 7000 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: %W[redis://:#{URI.encode_www_form_component('!&<123-abc>')}@127.0.0.1:7000])
    assert_equal({ '127.0.0.1:7000' => { ssl: false, password: '!&<123-abc>', host: '127.0.0.1', port: 7000 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: %w[redis://127.0.0.1:7000/0], db: 1)
    assert_equal({ '127.0.0.1:7000' => { ssl: false, host: '127.0.0.1', port: 7000, db: 0 } }, option.per_node_key)

    option = Redis::Cluster::Option.new(cluster: [{ host: '127.0.0.1', port: 7000 }])
    assert_equal({ '127.0.0.1:7000' => { host: '127.0.0.1', port: 7000 } }, option.per_node_key)

    assert_raises(Redis::InvalidClientOptionError) do
      Redis::Cluster::Option.new(cluster: nil)
    end

    assert_raises(Redis::InvalidClientOptionError) do
      Redis::Cluster::Option.new(cluster: %w[invalid_uri])
    end

    assert_raises(Redis::InvalidClientOptionError) do
      Redis::Cluster::Option.new(cluster: [{ host: '127.0.0.1' }])
    end
  end

  def test_client_accepts_valid_node_configs
    nodes = ['redis://127.0.0.1:7000',
             'redis://127.0.0.1:7001',
             { host: '127.0.0.1', port: '7002' },
             { 'host' => '127.0.0.1', port: 7003 },
             'redis://127.0.0.1:7004',
             'redis://127.0.0.1:7005']

    build_another_client(cluster: nodes)
  end

  def test_client_accepts_valid_options
    build_another_client(timeout: TIMEOUT)
  end

  def test_client_ignores_invalid_options
    build_another_client(invalid_option: true)
  end

  def test_client_works_even_if_so_many_unavailable_nodes_specified
    min = 7000
    max = min + Process.getrlimit(Process::RLIMIT_NOFILE).first / 3 * 2
    nodes = (min..max).map { |port| "redis://127.0.0.1:#{port}" }
    redis = build_another_client(cluster: nodes)

    assert_equal 'PONG', redis.ping
  end

  def test_client_does_not_accept_db_specified_url
    assert_raises(Redis::Cluster::InitialSetupError) do
      build_another_client(cluster: ['redis://127.0.0.1:7000/1/namespace'])
    end

    assert_raises(Redis::Cluster::InitialSetupError) do
      build_another_client(cluster: [{ host: '127.0.0.1', port: '7000' }], db: 1)
    end
  end

  def test_client_does_not_accept_unconnectable_node_url_only
    nodes = ['redis://127.0.0.1:7006']

    assert_raises(Redis::Cluster::InitialSetupError) do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_accepts_unconnectable_node_url_included
    nodes = ['redis://127.0.0.1:7000', 'redis://127.0.0.1:7006']

    build_another_client(cluster: nodes)
  end

  def test_client_does_not_accept_http_scheme_url
    nodes = ['http://127.0.0.1:80']

    assert_raises(Redis::InvalidClientOptionError, "invalid uri scheme 'http'") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_blank_included_config
    nodes = ['']

    assert_raises(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_bool_included_config
    nodes = [true]

    assert_raises(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_nil_included_config
    nodes = [nil]

    assert_raises(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_array_included_config
    nodes = [[]]

    assert_raises(Redis::InvalidClientOptionError, "invalid uri scheme ''") do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_empty_hash_included_config
    nodes = [{}]

    assert_raises(Redis::InvalidClientOptionError, 'Redis option of `cluster` must includes `:host` and `:port` keys') do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_object_included_config
    nodes = [Object.new]

    assert_raises(Redis::InvalidClientOptionError, 'Redis Cluster node config must includes String or Hash') do
      build_another_client(cluster: nodes)
    end
  end

  def test_client_does_not_accept_not_array_config
    nodes = :not_array

    assert_raises(Redis::InvalidClientOptionError, 'Redis Cluster node config must be Array') do
      build_another_client(cluster: nodes)
    end
  end
end
