# encoding: UTF-8

require "helper"

class TestBlockingCommands < Test::Unit::TestCase

  include Helper

  def setup
    super

    r.rpush("foo", "s1")
    r.rpush("foo", "s2")
    r.rpush("bar", "s1")
    r.rpush("bar", "s2")
  end

  def to_protocol(obj)
    case obj
    when String
      "$#{obj.length}\r\n#{obj}\r\n"
    when Array
      "*#{obj.length}\r\n" + obj.map { |e| to_protocol(e) }.join
    else
      fail
    end
  end

  def mock(&blk)
    replies = {
      :blpop => lambda do |*args|
        to_protocol([args.first, args.last])
      end,
      :brpop => lambda do |*args|
        to_protocol([args.first, args.last])
      end,
      :brpoplpush => lambda do |*args|
        to_protocol(args.last)
      end,
    }

    redis_mock(replies, &blk)
  end

  def test_blpop
    assert_equal ["foo", "s1"], r.blpop("foo")
    assert_equal ["foo", "s2"], r.blpop(["foo"])
    assert_equal ["bar", "s1"], r.blpop(["bar", "foo"])
    assert_equal ["bar", "s2"], r.blpop(["foo", "bar"])
  end

  def test_blpop_timeout
    mock do |r|
      assert_equal ["foo", "0"], r.blpop("foo")
      assert_equal ["foo", "1"], r.blpop("foo", :timeout => 1)
    end
  end

  def test_blpop_with_old_prototype
    assert_equal ["foo", "s1"], r.blpop("foo", 0)
    assert_equal ["foo", "s2"], r.blpop("foo", 0)
    assert_equal ["bar", "s1"], r.blpop("bar", "foo", 0)
    assert_equal ["bar", "s2"], r.blpop("foo", "bar", 0)
  end

  def test_blpop_timeout_with_old_prototype
    mock do |r|
      assert_equal ["foo", "0"], r.blpop("foo", 0)
      assert_equal ["foo", "1"], r.blpop("foo", 1)
    end
  end

  def test_brpop
    assert_equal ["foo", "s2"], r.brpop("foo")
    assert_equal ["foo", "s1"], r.brpop(["foo"])
    assert_equal ["bar", "s2"], r.brpop(["bar", "foo"])
    assert_equal ["bar", "s1"], r.brpop(["foo", "bar"])
  end

  def test_brpop_timeout
    mock do |r|
      assert_equal ["foo", "0"], r.brpop("foo")
      assert_equal ["foo", "1"], r.brpop("foo", :timeout => 1)
    end
  end

  def test_brpop_with_old_prototype
    assert_equal ["foo", "s2"], r.brpop("foo", 0)
    assert_equal ["foo", "s1"], r.brpop("foo", 0)
    assert_equal ["bar", "s2"], r.brpop("bar", "foo", 0)
    assert_equal ["bar", "s1"], r.brpop("foo", "bar", 0)
  end

  def test_brpop_timeout_with_old_prototype
    mock do |r|
      assert_equal ["foo", "0"], r.brpop("foo", 0)
      assert_equal ["foo", "1"], r.brpop("foo", 1)
    end
  end

  def test_brpoplpush
    assert_equal "s2", r.brpoplpush("foo", "zap")
    assert_equal ["s2"], r.lrange("zap", 0, -1)
  end

  def test_brpoplpush_timeout
    mock do |r|
      assert_equal "0", r.brpoplpush("foo", "bar")
      assert_equal "1", r.brpoplpush("foo", "bar", :timeout => 1)
    end
  end

  def test_brpoplpush_with_old_prototype
    assert_equal "s2", r.brpoplpush("foo", "zap", 0)
    assert_equal ["s2"], r.lrange("zap", 0, -1)
  end

  def test_brpoplpush_timeout_with_old_prototype
    mock do |r|
      assert_equal "0", r.brpoplpush("foo", "bar", 0)
      assert_equal "1", r.brpoplpush("foo", "bar", 1)
    end
  end
end
