# frozen_string_literal: true

require "helper"

class TestRedisInitialization < Minitest::Test
  def teardown
    Redis.default_configuration = {}
  end

  def test_initialize_without_default_configuration
    redis = Redis.new(host: "localhost", port: 6379)
    assert_equal "localhost", redis.instance_variable_get(:@options)[:host]
    assert_equal 6379, redis.instance_variable_get(:@options)[:port]
  end

  def test_initialize_with_default_configuration
    Redis.default_configuration = { host: "default_host", db: 1 }
    redis = Redis.new(port: 6380)
    options = redis.instance_variable_get(:@options)

    assert_equal "default_host", options[:host]
    assert_equal 6380, options[:port]
    assert_equal 1, options[:db]
  end

  def test_initialize_overriding_default_configuration
    Redis.default_configuration = { host: "default_host", port: 6379, db: 1 }
    redis = Redis.new(host: "custom_host", db: 2)
    options = redis.instance_variable_get(:@options)

    assert_equal "custom_host", options[:host]
    assert_equal 6379, options[:port]
    assert_equal 2, options[:db]
  end

  def test_initialize_with_nested_default_configuration
    Redis.default_configuration = {
      ssl: { verify_mode: 0 },
      timeout: { connect: 5, read: 5 }
    }
    redis = Redis.new(
      ssl: { ca_file: "/path/to/ca.crt" },
      timeout: { connect: 10 }
    )
    options = redis.instance_variable_get(:@options)

    assert_equal({ ca_file: "/path/to/ca.crt", verify_mode: 0 }, options[:ssl])
    assert_equal 10, options[:timeout][:connect]
    assert_equal 5, options[:timeout][:read]
  end

  def test_initialize_with_url
    Redis.default_configuration = { host: "default_host", port: 6379 }
    redis = Redis.new(url: "redis://custom_host:7000/2")
    options = redis.instance_variable_get(:@options)

    assert_equal "redis://custom_host:7000/2", options[:url]
    assert_equal "default_host", options[:host]
    assert_equal 6379, options[:port]
  end
end
