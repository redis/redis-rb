# frozen_string_literal: true

require_relative "helper"

class TestDistributedTransactions < Minitest::Test
  include Helper::Distributed

  def test_multi_discard
    r.set("foo", 1)

    r.watch("foo")
    r.multi
    r.set("foo", 2)

    assert_raises Redis::Distributed::CannotDistribute do
      r.set("bar", 1)
    end

    r.discard

    assert_equal('1', r.get("foo"))
  end

  def test_multi_discard_without_watch
    @foo = nil

    assert_raises Redis::Distributed::CannotDistribute do
      r.multi { @foo = 1 }
    end

    assert_nil @foo

    assert_raises Redis::Distributed::CannotDistribute do
      r.discard
    end
  end

  def test_watch_unwatch_without_clustering
    assert_raises Redis::Distributed::CannotDistribute do
      r.watch("foo", "bar")
    end

    r.watch("{qux}foo", "{qux}bar") do
      assert_raises Redis::Distributed::CannotDistribute do
        r.get("{baz}foo")
      end

      r.unwatch
    end

    assert_raises Redis::Distributed::CannotDistribute do
      r.unwatch
    end
  end

  def test_watch_with_exception
    assert_raises StandardError do
      r.watch("{qux}foo", "{qux}bar") do
        raise StandardError, "woops"
      end
    end

    assert_equal "OK", r.set("{other}baz", 1)
  end

  def test_watch_unwatch
    assert_equal "OK", r.watch("{qux}foo", "{qux}bar")
    assert_equal "OK", r.unwatch
  end

  def test_watch_multi_with_block
    r.set("{qux}baz", 1)

    r.watch("{qux}foo", "{qux}bar", "{qux}baz") do
      assert_equal '1', r.get("{qux}baz")

      result = r.multi do
        r.incrby("{qux}foo", 3)
        r.incrby("{qux}bar", 6)
        r.incrby("{qux}baz", 9)
      end

      assert_equal [3, 6, 10], result
    end
  end

  def test_watch_multi_exec_without_block
    r.set("{qux}baz", 1)

    assert_equal "OK", r.watch("{qux}foo", "{qux}bar", "{qux}baz")
    assert_equal '1', r.get("{qux}baz")

    assert_raises Redis::Distributed::CannotDistribute do
      r.get("{foo}baz")
    end

    assert_equal "OK", r.multi
    assert_equal "QUEUED", r.incrby("{qux}baz", 1)
    assert_equal "QUEUED", r.incrby("{qux}baz", 1)
    assert_equal [2, 3], r.exec

    assert_equal "OK", r.set("{other}baz", 1)
  end
end
