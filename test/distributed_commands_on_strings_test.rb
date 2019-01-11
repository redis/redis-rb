require_relative "helper"
require_relative "lint/strings"

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
    assert_raise Redis::Distributed::CannotDistribute do
      r.mset(:key1, "s1", :key4, "s2")
    end
  end

  def test_mset_mapped
    assert_raise Redis::Distributed::CannotDistribute do
      r.mapped_mset(:key1 => "s1", :key4 => "s2")
    end
  end

  def test_msetnx
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("key1", "s1")
      r.msetnx(:key1, "s2", :key4, "s3")
    end
  end

  def test_msetnx_mapped
    assert_raise Redis::Distributed::CannotDistribute do
      r.set("key1", "s1")
      r.mapped_msetnx(:key1 => "s2", :key4 => "s3")
    end
  end

  def test_bitop
    target_version "2.5.10" do
      assert_raise Redis::Distributed::CannotDistribute do
        r.set("key1", "a")
        r.set("key4", "b")

        r.bitop(:and, "key1&key4", "key1", "key4")
      end
    end
  end

  def test_mapped_mget_in_a_pipeline_returns_hash
    assert_raise Redis::Distributed::CannotDistribute do
      super
    end
  end
end
