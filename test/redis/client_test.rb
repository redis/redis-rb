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

  def test_mixed_encoding
    r.call("MSET", "fée", "\x00\xFF".b, "じ案".encode(Encoding::SHIFT_JIS), "\t".encode(Encoding::ASCII))
    assert_equal "\x00\xFF".b, r.call("GET", "fée")
    assert_equal "\t", r.call("GET", "じ案".encode(Encoding::SHIFT_JIS))

    r.call("SET", "\x00\xFF", "fée")
    assert_equal "fée", r.call("GET", "\x00\xFF".b)
  end

  def test_close_clear_pid
    assert_equal "PONG", r.ping
    fake_pid = Process.pid + 1
    Process.stubs(:pid).returns(fake_pid)

    assert_raises Redis::InheritedError do
      r.ping
    end

    r.close
    assert_equal "PONG", r.ping
  end
end
