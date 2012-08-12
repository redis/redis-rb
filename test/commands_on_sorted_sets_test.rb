# encoding: UTF-8

require "helper"
require "lint/sorted_sets"

class TestCommandsOnSortedSets < Test::Unit::TestCase

  include Helper::Client
  include Lint::SortedSets

  def test_zcount
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"

    assert_equal 2, r.zcount("foo", 2, 3)
  end

  def test_zunionstore
    r.zadd "foo", 1, "s1"
    r.zadd "bar", 2, "s2"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 4, "s4"

    assert_equal 4, r.zunionstore("foobar", ["foo", "bar"])
    assert_equal ["s1", "s2", "s3", "s4"], r.zrange("foobar", 0, -1)
  end
  
  def test_zunionstore_with_weights
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 20, "s2"
    r.zadd "bar", 40, "s4"

    assert_equal 4, r.zunionstore("foobar", ["foo", "bar"])
    assert_equal ["s1", "s3", "s2", "s4"], r.zrange("foobar", 0, -1)

    assert_equal 4, r.zunionstore("foobar", ["foo", "bar"], :weights => [10, 1])
    assert_equal ["s1", "s2", "s3", "s4"], r.zrange("foobar", 0, -1)
  end

  def test_zrange_with_scores
    r.zadd "foo", 1, "s1"
    r.zadd "bar", 2, "s2"
    r.zadd "baz", 3, "s3"
    r.zunionstore "foobarbaz", %w(foo bar baz), :weights => %w(-inf inf -1), :with_scores => true
    raw_res = r.zrange "foobarbaz", 0, -1, :with_scores => true
    res = {}
    raw_res.each { |val| res[val[0].to_sym] = val[1] }
    assert_equal({:s1 => -Float::INFINITY, :s2 => Float::INFINITY, :s3 => -3}, res)
  end
  
  def test_zunionstore_with_aggregate
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "bar", 4, "s2"
    r.zadd "bar", 3, "s3"

    assert_equal 3, r.zunionstore("foobar", ["foo", "bar"])
    assert_equal ["s1", "s3", "s2"], r.zrange("foobar", 0, -1)

    assert_equal 3, r.zunionstore("foobar", ["foo", "bar"], :aggregate => :min)
    assert_equal ["s1", "s2", "s3"], r.zrange("foobar", 0, -1)

    assert_equal 3, r.zunionstore("foobar", ["foo", "bar"], :aggregate => :max)
    assert_equal ["s1", "s3", "s2"], r.zrange("foobar", 0, -1)
  end

  def test_zinterstore
    r.zadd "foo", 1, "s1"
    r.zadd "bar", 2, "s1"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 4, "s4"

    assert_equal 1, r.zinterstore("foobar", ["foo", "bar"])
    assert_equal ["s1"], r.zrange("foobar", 0, -1)
  end

  def test_zinterstore_with_weights
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 20, "s2"
    r.zadd "bar", 30, "s3"
    r.zadd "bar", 40, "s4"

    assert_equal 2, r.zinterstore("foobar", ["foo", "bar"])
    assert_equal ["s2", "s3"], r.zrange("foobar", 0, -1)

    assert_equal 2, r.zinterstore("foobar", ["foo", "bar"], :weights => [10, 1])
    assert_equal ["s2", "s3"], r.zrange("foobar", 0, -1)

    assert_equal 40.0, r.zscore("foobar", "s2")
    assert_equal 60.0, r.zscore("foobar", "s3")
  end

  def test_zinterstore_with_aggregate
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"
    r.zadd "bar", 20, "s2"
    r.zadd "bar", 30, "s3"
    r.zadd "bar", 40, "s4"

    assert_equal 2, r.zinterstore("foobar", ["foo", "bar"])
    assert_equal ["s2", "s3"], r.zrange("foobar", 0, -1)
    assert_equal 22.0, r.zscore("foobar", "s2")
    assert_equal 33.0, r.zscore("foobar", "s3")

    assert_equal 2, r.zinterstore("foobar", ["foo", "bar"], :aggregate => :min)
    assert_equal ["s2", "s3"], r.zrange("foobar", 0, -1)
    assert_equal 2.0, r.zscore("foobar", "s2")
    assert_equal 3.0, r.zscore("foobar", "s3")

    assert_equal 2, r.zinterstore("foobar", ["foo", "bar"], :aggregate => :max)
    assert_equal ["s2", "s3"], r.zrange("foobar", 0, -1)
    assert_equal 20.0, r.zscore("foobar", "s2")
    assert_equal 30.0, r.zscore("foobar", "s3")
  end
end
