# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))
require "lint/strings"

class TestDistributedCommandsOnStrings < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Strings

  def test_mget
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal ["s1", "s2"]     , r.mget("foo", "bar")
    assert_equal ["s1", "s2", nil], r.mget("foo", "bar", "baz")
  end

  def test_mget_mapped
    r.set("foo", "s1")
    r.set("bar", "s2")

    response = r.mapped_mget("foo", "bar")

    assert_equal "s1", response["foo"]
    assert_equal "s2", response["bar"]

    response = r.mapped_mget("foo", "bar", "baz")

    assert_equal "s1", response["foo"]
    assert_equal "s2", response["bar"]
    assert_equal nil , response["baz"]
  end

  def test_mset
    r.mset(:foo, "s1", :bar, "s2")

    assert_equal "s1", r.get("foo")
    assert_equal "s2", r.get("bar")
  end

  def test_mset_mapped
    r.mapped_mset(:foo => "s1", :bar => "s2")

    assert_equal "s1", r.get("foo")
    assert_equal "s2", r.get("bar")
  end

  def test_msetnx
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("foo", "s1")
      r.msetnx(:foo, "s2", :bar, "s3")
    end
  end

  def test_msetnx_mapped
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("foo", "s1")
      r.mapped_msetnx(:foo => "s2", :bar => "s3")
    end
  end

  def test_bitop
    target_version "2.5.10" do
      assert_raise Redis::Distributed::CannotDistribute do
        r.set("foo", "a")
        r.set("bar", "b")

        r.bitop(:and, "foo&bar", "foo", "bar")
      end
    end
  end
end
