# frozen_string_literal: true

require "helper"

class TestDistributedTransactions < Minitest::Test
  include Helper::Distributed

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

      result = r.multi do |transaction|
        transaction.incrby("{qux}foo", 3)
        transaction.incrby("{qux}bar", 6)
        transaction.incrby("{qux}baz", 9)
      end

      assert_equal [3, 6, 10], result
    end

    assert_equal "OK", r.set("{other}baz", 1)
  end

  def test_watch_without_block_then_multi
    r.watch("{qux}foo")
    result = r.multi do |transaction|
      transaction.set("{qux}foo", 1)
    end

    assert_equal ["OK"], result

    assert_equal "OK", r.set("{other}baz", 1)
  end

  def test_watch_multi_then_explicit_unwatch
    r.watch("{qux}foo")
    r.multi do |transaction|
      transaction.set("{qux}foo", 1)
    end

    assert_equal "OK", r.set("{other}baz", 1)
    assert_equal "OK", r.unwatch

    assert_raises Redis::Distributed::CannotDistribute do
      r.unwatch
    end
  end

  def test_watch_block_multi_then_explicit_unwatch
    r.watch("{qux}foo") do
      r.multi do |transaction|
        transaction.set("{qux}foo", 1)
      end
    end

    assert_equal "OK", r.unwatch
  end

  def test_watch_then_two_multi
    r.watch("{qux}foo")
    r.multi do |transaction|
      transaction.set("{qux}foo", 1)
    end

    result = r.multi do |transaction|
      transaction.incr("{qux}foo")
    end

    assert_equal [2], result
  end

  def test_watch_then_empty_multi
    r.watch("{qux}foo")
    result = r.multi {}

    assert_equal [], result

    r.set("{qux}foo", 1)
    r.watch("{qux}bar")
    result = r.multi do |transaction|
      transaction.set("{qux}bar", 1)
    end

    assert_equal ["OK"], result
  end

  def test_watch_then_multi_with_failing_command
    r.set("{qux}str", "a")
    r.watch("{qux}foo")

    assert_raises(Redis::CommandError) do
      r.multi do |transaction|
        transaction.incr("{qux}str")
      end
    end

    assert_equal "OK", r.set("{other}baz", 1)
  end

  def test_watch_then_multi_with_exception_in_block
    r.watch("{qux}foo")

    assert_raises(RuntimeError) do
      r.multi do |transaction|
        transaction.set("{qux}foo", 1)
        raise "woops"
      end
    end

    Redis.new(OPTIONS).set("{qux}foo", 2)
    result = r.watch("{qux}foo") do
      r.multi do |transaction|
        transaction.set("{qux}foo", 3)
      end
    end

    assert_equal ["OK"], result
    assert_equal "OK", r.set("{other}baz", 1)
  end

  def test_watch_block_with_exception_after_watching_another_node
    assert_unwatches_other_node_after(RuntimeError)
  end

  def test_watch_block_with_connection_error_after_watching_another_node
    assert_unwatches_other_node_after(Redis::ConnectionError)
  end

  private

  def assert_unwatches_other_node_after(error_class)
    redis = Redis::Distributed.new(["redis://127.0.0.1:#{PORT}/14", *NODES], _format_options(protocol: PROTOCOL))
    first = "{qux}foo"
    other_tag = (1..100).map { |i| "{tag#{i}}foo" }.find { |key| redis.node_for(key).id != redis.node_for(first).id }
    other_db = redis.node_for(other_tag)._client.db

    assert_raises(error_class) do
      redis.watch(first) do
        redis.multi do |transaction|
          transaction.set(first, 1)
        end
        redis.watch(other_tag)
        raise error_class, "woops"
      end
    end

    Redis.new(OPTIONS.merge(db: other_db)).set(other_tag, 2)
    result = redis.watch(other_tag) do
      redis.multi do |transaction|
        transaction.set(other_tag, 3)
      end
    end

    assert_equal ["OK"], result
  ensure
    Redis.new(OPTIONS.merge(db: other_db)).del(other_tag) if other_db
    redis&.close
  end
end
