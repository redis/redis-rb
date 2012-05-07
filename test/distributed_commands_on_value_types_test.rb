# encoding: UTF-8

require "helper"
require "lint/value_types"

class TestDistributedCommandsOnValueTypes < Test::Unit::TestCase

  include Helper
  include Helper::Distributed
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
    assert_raise Redis::Distributed::CannotDistribute do
      r.randomkey
    end
  end

  def test_rename
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("foo", "s1")
      r.rename "foo", "bar"
    end

    assert "s1" == r.get("foo")
    assert nil == r.get("bar")
  end

  def test_renamenx
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("foo", "s1")
      r.rename "foo", "bar"
    end

    assert "s1" == r.get("foo")
    assert nil  == r.get("bar")
  end

  def test_dbsize
    assert [0] == r.dbsize

    r.set("foo", "s1")

    assert [1] == r.dbsize
  end

  def test_flushdb
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert [2] == r.dbsize

    r.flushdb

    assert [0] == r.dbsize
  end
end
