# encoding: UTF-8

require "helper"
require "lint/sorted_sets"

class TestCommandsOnSortedSets < Test::Unit::TestCase

  include Helper
  include Lint::SortedSets

  def test_zcount
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"

    assert 2 == r.zcount("foo", 2, 3)
  end

  def test_zunionstore
    r.zadd "foo", 1, "s1"
    r.zadd "bar", 2, "s2"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 4, "s4"

    assert 4 == r.zunionstore("foobar", ["foo", "bar"])
    assert ["s1", "s2", "s3", "s4"] == r.zrange("foobar", 0, -1)
  end

  def test_zunionstore_with_weights
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 20, "s2"
    r.zadd "bar", 40, "s4"

    assert 4 == r.zunionstore("foobar", ["foo", "bar"])
    assert ["s1", "s3", "s2", "s4"] == r.zrange("foobar", 0, -1)

    assert 4 == r.zunionstore("foobar", ["foo", "bar"], :weights => [10, 1])
    assert ["s1", "s2", "s3", "s4"] == r.zrange("foobar", 0, -1)
  end

  def test_zunionstore_with_aggregate
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "bar", 4, "s2"
    r.zadd "bar", 3, "s3"

    assert 3 == r.zunionstore("foobar", ["foo", "bar"])
    assert ["s1", "s3", "s2"] == r.zrange("foobar", 0, -1)

    assert 3 == r.zunionstore("foobar", ["foo", "bar"], :aggregate => :min)
    assert ["s1", "s2", "s3"] == r.zrange("foobar", 0, -1)

    assert 3 == r.zunionstore("foobar", ["foo", "bar"], :aggregate => :max)
    assert ["s1", "s3", "s2"] == r.zrange("foobar", 0, -1)
  end

  def test_zinterstore
    r.zadd "foo", 1, "s1"
    r.zadd "bar", 2, "s1"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 4, "s4"

    assert 1 == r.zinterstore("foobar", ["foo", "bar"])
    assert ["s1"] == r.zrange("foobar", 0, -1)
  end

  def test_zinterstore_with_weights
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 20, "s2"
    r.zadd "bar", 30, "s3"
    r.zadd "bar", 40, "s4"

    assert 2 == r.zinterstore("foobar", ["foo", "bar"])
    assert ["s2", "s3"] == r.zrange("foobar", 0, -1)

    assert 2 == r.zinterstore("foobar", ["foo", "bar"], :weights => [10, 1])
    assert ["s2", "s3"] == r.zrange("foobar", 0, -1)

    assert 40.0 == r.zscore("foobar", "s2")
    assert 60.0 == r.zscore("foobar", "s3")
  end

  def test_zinterstore_with_aggregate
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 20, "s2"
    r.zadd "bar", 30, "s3"
    r.zadd "bar", 40, "s4"

    assert 2 == r.zinterstore("foobar", ["foo", "bar"])
    assert ["s2", "s3"] == r.zrange("foobar", 0, -1)
    assert 22.0 == r.zscore("foobar", "s2")
    assert 33.0 == r.zscore("foobar", "s3")

    assert 2 == r.zinterstore("foobar", ["foo", "bar"], :aggregate => :min)
    assert ["s2", "s3"] == r.zrange("foobar", 0, -1)
    assert 2.0 == r.zscore("foobar", "s2")
    assert 3.0 == r.zscore("foobar", "s3")

    assert 2 == r.zinterstore("foobar", ["foo", "bar"], :aggregate => :max)
    assert ["s2", "s3"] == r.zrange("foobar", 0, -1)
    assert 20.0 == r.zscore("foobar", "s2")
    assert 30.0 == r.zscore("foobar", "s3")
  end
end
