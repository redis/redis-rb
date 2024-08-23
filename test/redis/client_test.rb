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

  def test_with_block
    result = r.call("INFO") { |l| l.lines(chomp: true).grep(/uptime_in_days/)[0] }
    assert_equal result, "uptime_in_days:0"
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

  def test_error_translate_subclasses
    error = Class.new(RedisClient::CommandError)
    assert_equal Redis::CommandError, Redis::Client.send(:translate_error_class, error)

    assert_raises KeyError do
      Redis::Client.send(:translate_error_class, StandardError)
    end
  end

  def test_mixed_encoding
    r.call("MSET", "fée", "\x00\xFF".b, "じ案".encode(Encoding::SHIFT_JIS), "\t".encode(Encoding::ASCII))
    assert_equal "\x00\xFF".b, r.call("GET", "fée")
    assert_equal "\t", r.call("GET", "じ案".encode(Encoding::SHIFT_JIS))

    r.call("SET", "\x00\xFF", "fée")
    assert_equal "fée", r.call("GET", "\x00\xFF".b)
  end
end
