require_relative "helper"

class TestClient < Test::Unit::TestCase

  include Helper::Client

  def test_call
    result = r.client.call(["PING"])
    assert_equal result, "PONG"
  end

  def test_call_with_arguments
    result = r.client.call(["SET", "foo", "bar"])
    assert_equal result, "OK"
  end

  def test_call_integers
    result = r.client.call(["INCR", "foo"])
    assert_equal result, 1
  end

  def test_call_raise
    assert_raises(Redis::CommandError) do
      r.client.call(["INCR"])
    end
  end

  def test_queue_commit
    r.client.queue(["SET", "foo", "bar"])
    r.client.queue(["GET", "foo"])
    result = r.client.commit

    assert_equal result, ["OK", "bar"]
  end

  def test_commit_raise
    r.client.queue(["SET", "foo", "bar"])
    r.client.queue(["INCR"])

    assert_raise(Redis::CommandError) do
      r.client.commit
    end
  end

  def test_queue_after_error
    r.client.queue(["SET", "foo", "bar"])
    r.client.queue(["INCR"])

    assert_raise(Redis::CommandError) do
      r.client.commit
    end

    r.client.queue(["SET",  "foo", "bar"])
    r.client.queue(["INCR", "baz"])
    result = r.client.commit

    assert_equal result, ["OK", 1]
  end
end
