# frozen_string_literal: true

require "helper"

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
      new_redis = _new_client(connector: custom_connector)
      new_redis.ping
    end
    assert_match(/Error connecting to Redis on 127\.0\.0\.5:999 (.+)/, error.message)
  end

  def test_mixed_encoding
    r.call("MSET", "fée", "\x00\xFF".b, "じ案".encode(Encoding::SHIFT_JIS), "\t".encode(Encoding::ASCII))
    assert_equal "\x00\xFF", r.call("GET", "fée")
    assert_equal "\t", r.call("GET", "じ案".encode(Encoding::SHIFT_JIS))

    r.call("SET", "\x00\xFF", "fée")
    assert_equal "fée", r.call("GET", "\x00\xFF".b)
  end
end
