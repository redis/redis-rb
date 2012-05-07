# encoding: UTF-8

require "helper"
require "lint/lists"

class TestCommandsOnLists < Test::Unit::TestCase

  include Helper
  include Lint::Lists

  def test_rpushx
    r.rpushx "foo", "s1"
    r.rpush "foo", "s2"
    r.rpushx "foo", "s3"

    assert 2 == r.llen("foo")
    assert ["s2", "s3"] == r.lrange("foo", 0, -1)
  end

  def test_lpushx
    r.lpushx "foo", "s1"
    r.lpush "foo", "s2"
    r.lpushx "foo", "s3"

    assert 2 == r.llen("foo")
    assert ["s3", "s2"] == r.lrange("foo", 0, -1)
  end

  def test_linsert
    r.rpush "foo", "s1"
    r.rpush "foo", "s3"
    r.linsert "foo", :before, "s3", "s2"

    assert ["s1", "s2", "s3"] == r.lrange("foo", 0, -1)

    assert_raise(Redis::CommandError) do
      r.linsert "foo", :anywhere, "s3", "s2"
    end
  end

  def test_rpoplpush
    r.rpush "foo", "s1"
    r.rpush "foo", "s2"

    assert "s2" == r.rpoplpush("foo", "bar")
    assert ["s2"] == r.lrange("bar", 0, -1)
    assert "s1" == r.rpoplpush("foo", "bar")
    assert ["s1", "s2"] == r.lrange("bar", 0, -1)
  end

  def test_brpoplpush
    r.rpush "foo", "s1"
    r.rpush "foo", "s2"

    assert_equal "s2", r.brpoplpush("foo", "bar", :timeout => 1)

    assert_equal nil, r.brpoplpush("baz", "qux", :timeout => 1)

    assert_equal ["s2"], r.lrange("bar", 0, -1)
  end
end
