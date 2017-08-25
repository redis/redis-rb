require_relative "helper"
require_relative "lint/sets"

class TestDistributedCommandsOnSets < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Sets

  def test_smove
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "bar", "s2"

      r.smove("foo", "bar", "s1")
    end
  end

  def test_sinter
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"

      r.sinter("foo", "bar")
    end
  end

  def test_sinterstore
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"

      r.sinterstore("baz", "foo", "bar")
    end
  end

  def test_sunion
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"
      r.sadd "bar", "s3"

      r.sunion("foo", "bar")
    end
  end

  def test_sunionstore
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"
      r.sadd "bar", "s3"

      r.sunionstore("baz", "foo", "bar")
    end
  end

  def test_sdiff
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"
      r.sadd "bar", "s3"

      r.sdiff("foo", "bar")
    end
  end

  def test_sdiffstore
    assert_raise Redis::Distributed::CannotDistribute do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"
      r.sadd "bar", "s3"

      r.sdiffstore("baz", "foo", "bar")
    end
  end

  def test_sscan
    assert_nothing_raised do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"
      r.sadd "bar", "s3"

      cursor, vals = r.sscan "foo", 0
      assert_equal '0', cursor
      assert_equal %w(s1 s2), vals.sort
    end
  end

  def test_sscan_each
    assert_nothing_raised do
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "bar", "s2"
      r.sadd "bar", "s3"

      vals = r.sscan_each("foo").to_a
      assert_equal %w(s1 s2), vals.sort
    end
  end
end
