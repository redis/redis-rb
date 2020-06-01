# frozen_string_literal: true
require_relative "helper"
require_relative "lint/value_types"

class TestDistributedCommandsOnValueTypes < Minitest::Test

  include Helper::Distributed
  include Lint::ValueTypes

  def test_del
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 1, r.del("foo")

    assert_equal ["bar", "baz"], r.keys("*").sort

    assert_equal 2, r.del("bar", "baz")

    assert_equal [], r.keys("*").sort
  end

  def test_del_with_array_argument
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 1, r.del(["foo"])

    assert_equal ["bar", "baz"], r.keys("*").sort

    assert_equal 2, r.del(["bar", "baz"])

    assert_equal [], r.keys("*").sort
  end

  def test_unlink
    target_version "4.0.0" do
      r.set "foo", "s1"
      r.set "bar", "s2"
      r.set "baz", "s3"

      assert_equal ["bar", "baz", "foo"], r.keys("*").sort

      assert_equal 1, r.unlink("foo")

      assert_equal ["bar", "baz"], r.keys("*").sort

      assert_equal 2, r.unlink("bar", "baz")

      assert_equal [], r.keys("*").sort
    end
  end

  def test_unlink_with_array_argument
    target_version "4.0.0" do
      r.set "foo", "s1"
      r.set "bar", "s2"
      r.set "baz", "s3"

      assert_equal ["bar", "baz", "foo"], r.keys("*").sort

      assert_equal 1, r.unlink(["foo"])

      assert_equal ["bar", "baz"], r.keys("*").sort

      assert_equal 2, r.unlink(["bar", "baz"])

      assert_equal [], r.keys("*").sort
    end
  end

  def test_randomkey
    assert_raises Redis::Distributed::CannotDistribute do
      r.randomkey
    end
  end

  def test_rename
    assert_raises Redis::Distributed::CannotDistribute do
      r.set("foo", "s1")
      r.rename "foo", "bar"
    end

    assert_equal "s1", r.get("foo")
    assert_nil r.get("bar")
  end

  def test_renamenx
    assert_raises Redis::Distributed::CannotDistribute do
      r.set("foo", "s1")
      r.rename "foo", "bar"
    end

    assert_equal "s1", r.get("foo")
    assert_nil r.get("bar")
  end

  def test_dbsize
    assert_equal [0], r.dbsize

    r.set("foo", "s1")

    assert_equal [1], r.dbsize
  end

  def test_flushdb
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal [2], r.dbsize

    r.flushdb

    assert_equal [0], r.dbsize
  end

  def test_migrate
    r.set("foo", "s1")

    assert_raises Redis::Distributed::CannotDistribute do
      r.migrate("foo", {})
    end
  end

  def test_exists_with_multiple_arguements
    target_version "3.0.3" do
      assert_equal false, r.exists("foo")

      r.set("foo", "s1")

      assert_equal true,  r.exists("foo")
      assert_equal true, r.exists("foo", "foo2")

      r.set("foo2", "s1")

      assert_equal true, r.exists("foo", "foo2")
      assert_equal true, r.exists("foo", "foo2", "foo3")
      assert_equal false, r.exists("foo3", "foo4")
    end
  end
end
