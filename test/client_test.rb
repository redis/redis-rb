# frozen_string_literal: true
require_relative "helper"

class TestClient < Minitest::Test

  include Helper::Client

  def test_call
    result = r.call("PING")
    assert_equal result, "PONG"
  end

  def test_call_with_arguments
    result = r.call("SET", "foo", "bar")
    assert_equal result, "OK"
  end

  def test_call_integers
    result = r.call("INCR", "foo")
    assert_equal result, 1
  end

  def test_call_raise
    assert_raises(Redis::CommandError) do
      r.call("INCR")
    end
  end

  def test_queue_commit
    r.queue("SET", "foo", "bar")
    r.queue("GET", "foo")
    result = r.commit

    assert_equal result, ["OK", "bar"]
  end

  def test_commit_raise
    r.queue("SET", "foo", "bar")
    r.queue("INCR")

    assert_raises(Redis::CommandError) do
      r.commit
    end
  end

  def test_queue_after_error
    r.queue("SET", "foo", "bar")
    r.queue("INCR")

    assert_raises(Redis::CommandError) do
      r.commit
    end

    r.queue("SET",  "foo", "bar")
    r.queue("INCR", "baz")
    result = r.commit

    assert_equal result, ["OK", 1]
  end

  def test_client_with_custom_connector
    custom_connector = Class.new(Redis::Client::Connector) do
      def resolve
        @options[:host] = '127.0.0.5'
        @options[:port] = '999'
        @options
      end
    end

    error = assert_raises do
      new_redis = new_client(connector: custom_connector)
      new_redis.ping
    end
    assert_equal 'Error connecting to Redis on 127.0.0.5:999 (Errno::ECONNREFUSED)', error.message
  end

  def test_client_connect_disconnect_hooks
    custom_connector = Class.new(Redis::Client::Connector) do
      attr_reader :connect_called, :disconnect_called

      def check(client)
        @connect_called = true
      end

      def on_disconnect(client)
        @disconnect_called = true
      end
    end

    redis = new_client(connector: custom_connector)
    redis.ping
    redis.close

    connector = redis._client.instance_variable_get(:@connector)

    assert connector.connect_called
    assert connector.disconnect_called
  end
end
