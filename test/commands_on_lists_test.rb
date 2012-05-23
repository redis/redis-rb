# encoding: UTF-8

require "helper"
require "lint/lists"

class TestCommandsOnLists < Test::Unit::TestCase

  include Helper::Client
  include Lint::Lists

  def test_linsert
    r.rpush "foo", "s1"
    r.rpush "foo", "s3"
    r.linsert "foo", :before, "s3", "s2"

    assert_equal ["s1", "s2", "s3"], r.lrange("foo", 0, -1)

    assert_raise(Redis::CommandError) do
      r.linsert "foo", :anywhere, "s3", "s2"
    end
  end

  def test_rpoplpush
    r.rpush "foo", "s1"
    r.rpush "foo", "s2"

    assert_equal "s2", r.rpoplpush("foo", "bar")
    assert_equal ["s2"], r.lrange("bar", 0, -1)
    assert_equal "s1", r.rpoplpush("foo", "bar")
    assert_equal ["s1", "s2"], r.lrange("bar", 0, -1)
  end
end
