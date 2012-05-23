# encoding: UTF-8

require "helper"
require "lint/strings"

class TestCommandsOnStrings < Test::Unit::TestCase

  include Helper::Client
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

  def test_mapped_mget_in_a_pipeline_returns_hash
    r.set("foo", "s1")
    r.set("bar", "s2")

    result = r.pipelined do
      r.mapped_mget("foo", "bar")
    end

    assert_equal result[0], { "foo" => "s1", "bar" => "s2" }
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
    r.set("foo", "s1")
    assert_equal false, r.msetnx(:foo, "s2", :bar, "s3")
    assert_equal "s1", r.get("foo")
    assert_equal nil, r.get("bar")

    r.del("foo")
    assert_equal true, r.msetnx(:foo, "s2", :bar, "s3")
    assert_equal "s2", r.get("foo")
    assert_equal "s3", r.get("bar")
  end

  def test_msetnx_mapped
    r.set("foo", "s1")
    assert_equal false, r.mapped_msetnx(:foo => "s2", :bar => "s3")
    assert_equal "s1", r.get("foo")
    assert_equal nil, r.get("bar")

    r.del("foo")
    assert_equal true, r.mapped_msetnx(:foo => "s2", :bar => "s3")
    assert_equal "s2", r.get("foo")
    assert_equal "s3", r.get("bar")
  end
end
