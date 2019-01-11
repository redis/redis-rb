require_relative "helper"
require_relative "lint/value_types"

class TestDistributedCommandsOnValueTypes < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::ValueTypes

  def test_move
    assert_raise(Redis::Distributed::CannotDistribute) { super }

    r.set('key1', 'v1')
    assert r.move('key1', 14)
    assert_equal nil, r.get('key1')
  end

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
    assert_raise Redis::Distributed::CannotDistribute do
      r.randomkey
    end
  end

  def test_rename
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("key1", "s1")
      r.rename "key1", "key4"
    end

    assert_equal "s1", r.get("key1")
    assert_equal nil, r.get("key4")
  end

  def test_renamenx
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("key1", "s1")
      r.rename "key1", "key4"
    end

    assert_equal "s1", r.get("key1")
    assert_equal nil , r.get("key4")
  end

  def test_dbsize
    assert_equal [0, 0], r.dbsize

    r.set("key1", "s1")

    assert_equal [1, 0], r.dbsize
  end

  def test_flushdb
    r.set("key1", "s1")
    r.set("key4", "s2")

    assert_equal [1, 1], r.dbsize

    r.flushdb

    assert_equal [0, 0], r.dbsize
  end

  def test_migrate
    r.set("foo", "s1")

    assert_raise Redis::Distributed::CannotDistribute do
      r.migrate('foo', host: '127.0.0.1', port: PORT)
    end
  end
end
