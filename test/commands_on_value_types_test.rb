# encoding: UTF-8

require "helper"
require "lint/value_types"

class TestCommandsOnValueTypes < Test::Unit::TestCase

  include Helper
  include Lint::ValueTypes

  def test_del
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert ["bar", "baz", "foo"] == r.keys("*").sort

    assert 1 == r.del("foo")

    assert ["bar", "baz"] == r.keys("*").sort

    assert 2 == r.del("bar", "baz")

    assert [] == r.keys("*").sort
  end

  def test_del_with_array_argument
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert ["bar", "baz", "foo"] == r.keys("*").sort

    assert 1 == r.del(["foo"])

    assert ["bar", "baz"] == r.keys("*").sort

    assert 2 == r.del(["bar", "baz"])

    assert [] == r.keys("*").sort
  end

  def test_randomkey
    assert r.randomkey.to_s.empty?

    r.set("foo", "s1")

    assert "foo" == r.randomkey

    r.set("bar", "s2")

    4.times do
      assert ["foo", "bar"].include?(r.randomkey)
    end
  end

  def test_rename
    r.set("foo", "s1")
    r.rename "foo", "bar"

    assert "s1" == r.get("bar")
    assert nil == r.get("foo")
  end

  def test_renamenx
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert false == r.renamenx("foo", "bar")

    assert "s1" == r.get("foo")
    assert "s2" == r.get("bar")
  end

  def test_dbsize
    assert 0 == r.dbsize

    r.set("foo", "s1")

    assert 1 == r.dbsize
  end

  def test_flushdb
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert 2 == r.dbsize

    r.flushdb

    assert 0 == r.dbsize
  end

  def test_flushall
    redis_mock(:flushall => lambda { "+FLUSHALL" }) do
      redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

      assert "FLUSHALL" == redis.flushall
    end
  end
end
