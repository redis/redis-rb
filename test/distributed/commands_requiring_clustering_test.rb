# frozen_string_literal: true

require "helper"

class TestDistributedCommandsRequiringClustering < Minitest::Test
  include Helper::Distributed

  def test_rename
    r.set("{qux}foo", "s1")
    r.rename "{qux}foo", "{qux}bar"

    assert_equal "s1", r.get("{qux}bar")
    assert_nil r.get("{qux}foo")
  end

  def test_renamenx
    r.set("{qux}foo", "s1")
    r.set("{qux}bar", "s2")

    assert_equal false, r.renamenx("{qux}foo", "{qux}bar")

    assert_equal "s1", r.get("{qux}foo")
    assert_equal "s2", r.get("{qux}bar")
  end

  def test_lmove
    target_version "6.2" do
      r.rpush("{qux}foo", "s1")
      r.rpush("{qux}foo", "s2")
      r.rpush("{qux}bar", "s3")
      r.rpush("{qux}bar", "s4")

      assert_equal "s1", r.lmove("{qux}foo", "{qux}bar", "LEFT", "RIGHT")
      assert_equal ["s2"], r.lrange("{qux}foo", 0, -1)
      assert_equal ["s3", "s4", "s1"], r.lrange("{qux}bar", 0, -1)
    end
  end

  def test_brpoplpush
    r.rpush "{qux}foo", "s1"
    r.rpush "{qux}foo", "s2"

    assert_equal "s2", r.brpoplpush("{qux}foo", "{qux}bar", timeout: 1)
    assert_equal ["s2"], r.lrange("{qux}bar", 0, -1)
  end

  def test_rpoplpush
    r.rpush "{qux}foo", "s1"
    r.rpush "{qux}foo", "s2"

    assert_equal "s2", r.rpoplpush("{qux}foo", "{qux}bar")
    assert_equal ["s2"], r.lrange("{qux}bar", 0, -1)
    assert_equal "s1", r.rpoplpush("{qux}foo", "{qux}bar")
    assert_equal ["s1", "s2"], r.lrange("{qux}bar", 0, -1)
  end

  def test_smove
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}bar", "s2"

    assert r.smove("{qux}foo", "{qux}bar", "s1")
    assert r.sismember("{qux}bar", "s1")
  end

  def test_sinter
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}foo", "s2"
    r.sadd "{qux}bar", "s2"

    assert_equal ["s2"], r.sinter("{qux}foo", "{qux}bar")
  end

  def test_sinterstore
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}foo", "s2"
    r.sadd "{qux}bar", "s2"

    r.sinterstore("{qux}baz", "{qux}foo", "{qux}bar")

    assert_equal ["s2"], r.smembers("{qux}baz")
  end

  def test_sunion
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}foo", "s2"
    r.sadd "{qux}bar", "s2"
    r.sadd "{qux}bar", "s3"

    assert_equal ["s1", "s2", "s3"], r.sunion("{qux}foo", "{qux}bar").sort
  end

  def test_sunionstore
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}foo", "s2"
    r.sadd "{qux}bar", "s2"
    r.sadd "{qux}bar", "s3"

    r.sunionstore("{qux}baz", "{qux}foo", "{qux}bar")

    assert_equal ["s1", "s2", "s3"], r.smembers("{qux}baz").sort
  end

  def test_sdiff
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}foo", "s2"
    r.sadd "{qux}bar", "s2"
    r.sadd "{qux}bar", "s3"

    assert_equal ["s1"], r.sdiff("{qux}foo", "{qux}bar")
    assert_equal ["s3"], r.sdiff("{qux}bar", "{qux}foo")
  end

  def test_sdiffstore
    r.sadd "{qux}foo", "s1"
    r.sadd "{qux}foo", "s2"
    r.sadd "{qux}bar", "s2"
    r.sadd "{qux}bar", "s3"

    r.sdiffstore("{qux}baz", "{qux}foo", "{qux}bar")

    assert_equal ["s1"], r.smembers("{qux}baz")
  end

  def test_sort
    r.set("{qux}foo:1", "s1")
    r.set("{qux}foo:2", "s2")

    r.rpush("{qux}bar", "1")
    r.rpush("{qux}bar", "2")

    assert_equal ["s1"], r.sort("{qux}bar", get: "{qux}foo:*", limit: [0, 1])
    assert_equal ["s2"], r.sort("{qux}bar", get: "{qux}foo:*", limit: [0, 1], order: "desc alpha")
  end

  def test_sort_with_an_array_of_gets
    r.set("{qux}foo:1:a", "s1a")
    r.set("{qux}foo:1:b", "s1b")

    r.set("{qux}foo:2:a", "s2a")
    r.set("{qux}foo:2:b", "s2b")

    r.rpush("{qux}bar", "1")
    r.rpush("{qux}bar", "2")

    assert_equal [["s1a", "s1b"]], r.sort("{qux}bar", get: ["{qux}foo:*:a", "{qux}foo:*:b"], limit: [0, 1])
    assert_equal [["s2a", "s2b"]], r.sort("{qux}bar", get: ["{qux}foo:*:a", "{qux}foo:*:b"], limit: [0, 1], order: "desc alpha")
    assert_equal [["s1a", "s1b"], ["s2a", "s2b"]], r.sort("{qux}bar", get: ["{qux}foo:*:a", "{qux}foo:*:b"])
  end

  def test_sort_with_store
    r.set("{qux}foo:1", "s1")
    r.set("{qux}foo:2", "s2")

    r.rpush("{qux}bar", "1")
    r.rpush("{qux}bar", "2")

    r.sort("{qux}bar", get: "{qux}foo:*", store: "{qux}baz")
    assert_equal ["s1", "s2"], r.lrange("{qux}baz", 0, -1)
  end

  def test_sort_ro
    target_version "7.0.0" do
      r.set("{qux}foo:1", "s1")
      r.set("{qux}foo:2", "s2")

      r.rpush("{qux}bar", "1")
      r.rpush("{qux}bar", "2")

      assert_equal ["s1"], r.sort_ro("{qux}bar", get: "{qux}foo:*", limit: [0, 1])
      assert_equal ["s2"], r.sort_ro("{qux}bar", get: "{qux}foo:*", limit: [0, 1], order: "desc alpha")
    end
  end

  def test_sort_ro_with_an_array_of_gets
    target_version "7.0.0" do
      r.set("{qux}foo:1:a", "s1a")
      r.set("{qux}foo:1:b", "s1b")

      r.set("{qux}foo:2:a", "s2a")
      r.set("{qux}foo:2:b", "s2b")

      r.rpush("{qux}bar", "1")
      r.rpush("{qux}bar", "2")

      assert_equal [["s1a", "s1b"], ["s2a", "s2b"]], r.sort_ro("{qux}bar", get: ["{qux}foo:*:a", "{qux}foo:*:b"])
    end
  end

  def test_sort_with_get_hash_returns_the_element_itself
    r.set("{qux}foo:1", "s1")
    r.set("{qux}foo:2", "s2")

    r.rpush("{qux}bar", "1")
    r.rpush("{qux}bar", "2")

    # `GET #` is not a key and must not take part in same-node routing.
    assert_equal %w[1 2], r.sort("{qux}bar", get: "#")
    assert_equal [["1", "s1"], ["2", "s2"]], r.sort("{qux}bar", get: ["#", "{qux}foo:*"])
  end

  def test_sort_ro_with_get_hash_returns_the_element_itself
    target_version "7.0.0" do
      r.set("{qux}foo:1", "s1")
      r.set("{qux}foo:2", "s2")

      r.rpush("{qux}bar", "1")
      r.rpush("{qux}bar", "2")

      assert_equal %w[1 2], r.sort_ro("{qux}bar", get: "#")
      assert_equal [["1", "s1"], ["2", "s2"]], r.sort_ro("{qux}bar", get: ["#", "{qux}foo:*"])
    end
  end

  def test_sort_with_by_nosort_keeps_insertion_order
    r.rpush("{qux}bar", "2")
    r.rpush("{qux}bar", "1")

    # A constant BY pattern skips sorting and reads no key, so it must not affect routing.
    assert_equal %w[2 1], r.sort("{qux}bar", by: "nosort")
    assert_equal %w[1 2], r.sort("{qux}bar")
  end

  def test_sort_ro_with_by_nosort_keeps_insertion_order
    target_version "7.0.0" do
      r.rpush("{qux}bar", "2")
      r.rpush("{qux}bar", "1")

      assert_equal %w[2 1], r.sort_ro("{qux}bar", by: "nosort")
      assert_equal %w[1 2], r.sort_ro("{qux}bar")
    end
  end

  def test_bitop
    r.set("{qux}foo", "a")
    r.set("{qux}bar", "b")

    r.bitop(:and, "{qux}foo&bar", "{qux}foo", "{qux}bar")
    assert_equal "\x60", r.get("{qux}foo&bar")
    r.bitop(:or, "{qux}foo|bar", "{qux}foo", "{qux}bar")
    assert_equal "\x63", r.get("{qux}foo|bar")
    r.bitop(:xor, "{qux}foo^bar", "{qux}foo", "{qux}bar")
    assert_equal "\x03", r.get("{qux}foo^bar")
    r.bitop(:not, "{qux}~foo", "{qux}foo")
    assert_equal "\x9E".b, r.get("{qux}~foo")
  end
end
