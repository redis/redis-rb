# encoding: UTF-8

require "helper"

class TestTransactions < Test::Unit::TestCase

  include Helper

  def test_multi_discard
    r.multi

    assert "QUEUED" == r.set("foo", "1")
    assert "QUEUED" == r.get("foo")

    r.discard

    assert nil == r.get("foo")
  end

  def test_multi_exec_with_a_block
    r.multi do |multi|
      multi.set "foo", "s1"
    end

    assert "s1" == r.get("foo")
  end

  def test_multi_exec_with_a_block_doesn_t_return_replies_for_multi_and_exec
    r1, r2, nothing_else = r.multi do |multi|
      multi.set "foo", "s1"
      multi.get "foo"
    end

    assert_equal "OK", r1
    assert_equal "s1", r2
    assert_equal nil, nothing_else
  end

  def test_assignment_inside_multi_exec_block
    r.multi do |m|
      @first = m.sadd("foo", 1)
      @second = m.sadd("foo", 1)
    end

    assert_equal true, @first.value
    assert_equal false, @second.value
  end

  # Although we could support accessing the values in these futures,
  # it doesn't make a lot of sense.
  def test_assignment_inside_multi_exec_block_with_delayed_command_errors
    assert_raise(Redis::CommandError) do
      r.multi do |m|
        @first = m.set("foo", "s1")
        @second = m.incr("foo") # not an integer
        @third = m.lpush("foo", "value") # wrong kind of value
      end
    end

    assert_equal "OK", @first.value
    assert_raise(Redis::CommandError) { @second.value }
    assert_raise(Redis::FutureNotReady) { @third.value }
  end

  def test_assignment_inside_multi_exec_block_with_immediate_command_errors
    assert_raise(Redis::CommandError) do
      r.multi do |m|
        m.doesnt_exist
        @first = m.sadd("foo", 1)
        m.doesnt_exist
        @second = m.sadd("foo", 1)
        m.doesnt_exist
      end
    end

    assert_raise(Redis::FutureNotReady) { @first.value }
    assert_raise(Redis::FutureNotReady) { @second.value }
  end

  def test_raise_immediate_errors_in_multi_exec
    assert_raise(RuntimeError) do
      r.multi do |multi|
        multi.set "bar", "s2"
        raise "Some error"
        multi.set "baz", "s3"
      end
    end

    assert nil == r.get("bar")
    assert nil == r.get("baz")
  end

  def test_transformed_replies_as_return_values_for_multi_exec_block
    info, _ = r.multi do |m|
      r.info
    end

    assert info.kind_of?(Hash)
  end

  def test_transformed_replies_inside_multi_exec_block
    r.multi do |m|
      @info = r.info
    end

    assert @info.value.kind_of?(Hash)
  end

  def test_raise_command_errors_in_multi_exec
    assert_raise(Redis::CommandError) do
      r.multi do |m|
        m.set("foo", "s1")
        m.incr("foo") # not an integer
        m.lpush("foo", "value") # wrong kind of value
      end
    end

    assert "s1" == r.get("foo")
  end

  def test_raise_command_errors_when_accessing_futures_after_multi_exec
    begin
      r.multi do |m|
        m.set("foo", "s1")
        @counter = m.incr("foo") # not an integer
      end
    rescue Exception
      # Not gonna deal with it
    end

    # We should test for Redis::Error here, but hiredis doesn't yet do
    # custom error classes.
    err = nil
    begin
      @counter.value
    rescue => err
    end

    assert err.kind_of?(RuntimeError)
  end

  def test_multi_with_a_block_yielding_the_client
    r.multi do |multi|
      multi.set "foo", "s1"
    end

    assert "s1" == r.get("foo")
  end

  def test_watch_with_an_unmodified_key
    r.watch "foo"
    r.multi do |multi|
      multi.set "foo", "s1"
    end

    assert "s1" == r.get("foo")
  end

  def test_watch_with_an_unmodified_key_passed_as_array
    r.watch ["foo", "bar"]
    r.multi do |multi|
      multi.set "foo", "s1"
    end

    assert "s1" == r.get("foo")
  end

  def test_watch_with_a_modified_key
    r.watch "foo"
    r.set "foo", "s1"
    res = r.multi do |multi|
      multi.set "foo", "s2"
    end

    assert nil == res
    assert "s1" == r.get("foo")
  end

  def test_watch_with_a_modified_key_passed_as_array
    r.watch ["foo", "bar"]
    r.set "foo", "s1"
    res = r.multi do |multi|
      multi.set "foo", "s2"
    end

    assert nil == res
    assert "s1" == r.get("foo")
  end

  def test_unwatch_with_a_modified_key
    r.watch "foo"
    r.set "foo", "s1"
    r.unwatch
    r.multi do |multi|
      multi.set "foo", "s2"
    end

    assert "s2" == r.get("foo")
  end
end
