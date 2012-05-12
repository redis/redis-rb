# encoding: UTF-8

require "helper"

class TestBlockingCommands < Test::Unit::TestCase

  include Helper

  # Time to give a timeout of 1 to expire
  SLACK = 2.5

  def create
    r.lpush("foo", "s1")
    r.lpush("foo", "s2")
  end

  def push(options)
    wire = Wire.new do
      redis = Redis.new(OPTIONS)
      Wire.sleep 0.1
      redis.lpush(options[:to], "s3")
    end

    yield

  ensure
    wire.join
  end

  def test_blpop
    create

    push(:to => "foo") do
      assert_equal ["foo", "s2"], r.blpop("foo", :timeout => 1)
      assert_equal ["foo", "s1"], r.blpop("foo", :timeout => 1)
      assert_equal ["foo", "s3"], r.blpop("foo", :timeout => 1)
    end
  end

  def test_blpop_with_multiple_keys
    create

    push(:to => "bar") do
      assert_equal ["foo", "s2"], r.blpop(["bar", "foo"], :timeout => 1)
      assert_equal ["foo", "s1"], r.blpop(["bar", "foo"], :timeout => 1)
      assert_equal ["bar", "s3"], r.blpop(["bar", "foo"], :timeout => 1)
    end
  end

  def test_blpop_timeout
    assert_finishes_in(SLACK) do
      assert_equal nil, r.blpop("foo", :timeout => 1)
    end
  end

  def test_blpop_with_old_prototype
    create

    push(:to => "bar") do
      assert_equal ["foo", "s2"], r.blpop("bar", "foo", 1)
      assert_equal ["foo", "s1"], r.blpop("bar", "foo", 1)
      assert_equal ["bar", "s3"], r.blpop("bar", "foo", 1)
    end
  end

  def test_blpop_timeout_with_old_prototype
    assert_finishes_in(SLACK) do
      assert_equal nil, r.blpop("foo", 1)
    end
  end

  def test_brpop
    create

    push(:to => "foo") do
      assert_equal ["foo", "s1"], r.brpop("foo", :timeout => 1)
      assert_equal ["foo", "s2"], r.brpop("foo", :timeout => 1)
      assert_equal ["foo", "s3"], r.brpop("foo", :timeout => 1)
    end
  end

  def test_brpop_with_multiple_keys
    create

    push(:to => "bar") do
      assert_equal ["foo", "s1"], r.brpop(["bar", "foo"], :timeout => 1)
      assert_equal ["foo", "s2"], r.brpop(["bar", "foo"], :timeout => 1)
      assert_equal ["bar", "s3"], r.brpop(["bar", "foo"], :timeout => 1)
    end
  end

  def test_brpop_timeout
    assert_finishes_in(SLACK) do
      assert_equal nil, r.brpop("foo", :timeout => 1)
    end
  end

  def test_brpop_with_old_prototype
    create

    push(:to => "bar") do
      assert_equal ["foo", "s1"], r.brpop("bar", "foo", 1)
      assert_equal ["foo", "s2"], r.brpop("bar", "foo", 1)
      assert_equal ["bar", "s3"], r.brpop("bar", "foo", 1)
    end
  end

  def test_brpop_timeout_with_old_prototype
    assert_finishes_in(SLACK) do
      assert_equal nil, r.brpop("foo", 1)
    end
  end

  def test_brpoplpush
    create

    assert_equal "s1", r.brpoplpush("foo", "bar", :timeout => 1)

    assert_equal nil, r.brpoplpush("baz", "qux", :timeout => 1)

    assert_equal ["s1"], r.lrange("bar", 0, -1)
  end

  def test_brpoplpush_timeout
    assert_finishes_in(SLACK) do
      assert_equal nil, r.brpoplpush("foo", "bar", :timeout => 1)
    end
  end

  def test_brpoplpush_with_old_prototype
    create

    assert_equal "s1", r.brpoplpush("foo", "bar", 1)

    assert_equal nil, r.brpoplpush("baz", "qux", 1)

    assert_equal ["s1"], r.lrange("bar", 0, -1)
  end

  def test_brpoplpush_timeout_with_old_prototype
    assert_finishes_in(SLACK) do
      assert_equal nil, r.brpoplpush("foo", "bar", 1)
    end
  end
end
