# frozen_string_literal: true

require "helper"

class TestSorting < Minitest::Test
  include Helper::Client

  def test_sort
    r.set("foo:1", "s1")
    r.set("foo:2", "s2")

    r.rpush("bar", "1")
    r.rpush("bar", "2")

    assert_equal ["s1"], r.sort("bar", get: "foo:*", limit: [0, 1])
    assert_equal ["s2"], r.sort("bar", get: "foo:*", limit: [0, 1], order: "desc alpha")
  end

  def test_sort_with_an_array_of_gets
    r.set("foo:1:a", "s1a")
    r.set("foo:1:b", "s1b")

    r.set("foo:2:a", "s2a")
    r.set("foo:2:b", "s2b")

    r.rpush("bar", "1")
    r.rpush("bar", "2")

    assert_equal [["s1a", "s1b"]], r.sort("bar", get: ["foo:*:a", "foo:*:b"], limit: [0, 1])
    assert_equal [["s2a", "s2b"]], r.sort("bar", get: ["foo:*:a", "foo:*:b"], limit: [0, 1], order: "desc alpha")
    assert_equal [["s1a", "s1b"], ["s2a", "s2b"]], r.sort("bar", get: ["foo:*:a", "foo:*:b"])
  end

  def test_sort_with_store
    r.set("foo:1", "s1")
    r.set("foo:2", "s2")

    r.rpush("bar", "1")
    r.rpush("bar", "2")

    r.sort("bar", get: "foo:*", store: "baz")
    assert_equal ["s1", "s2"], r.lrange("baz", 0, -1)
  end

  def test_sort_with_an_array_of_gets_and_with_store
    r.set("foo:1:a", "s1a")
    r.set("foo:1:b", "s1b")

    r.set("foo:2:a", "s2a")
    r.set("foo:2:b", "s2b")

    r.rpush("bar", "1")
    r.rpush("bar", "2")

    r.sort("bar", get: ["foo:*:a", "foo:*:b"], store: 'baz')
    assert_equal ["s1a", "s1b", "s2a", "s2b"], r.lrange("baz", 0, -1)
  end

  def test_sort_ro
    target_version "7.0.0" do
      r.rpush("bar", %w[3 1 2])

      assert_equal %w[1 2 3], r.sort_ro("bar")
      assert_equal %w[3 2], r.sort_ro("bar", order: "desc", limit: [0, 2])
    end
  end

  def test_sort_ro_with_get
    target_version "7.0.0" do
      r.set("foo:1", "s1")
      r.set("foo:2", "s2")

      r.rpush("bar", %w[1 2])

      assert_equal ["s1"], r.sort_ro("bar", get: "foo:*", limit: [0, 1])
      assert_equal ["s2"], r.sort_ro("bar", get: "foo:*", limit: [0, 1], order: "desc alpha")
    end
  end

  def test_sort_ro_with_an_array_of_gets
    target_version "7.0.0" do
      r.set("foo:1:a", "s1a")
      r.set("foo:1:b", "s1b")

      r.set("foo:2:a", "s2a")
      r.set("foo:2:b", "s2b")

      r.rpush("bar", %w[1 2])

      assert_equal [["s1a", "s1b"]], r.sort_ro("bar", get: ["foo:*:a", "foo:*:b"], limit: [0, 1])
      assert_equal [["s2a", "s2b"]], r.sort_ro("bar", get: ["foo:*:a", "foo:*:b"], limit: [0, 1], order: "desc alpha")
      assert_equal [["s1a", "s1b"], ["s2a", "s2b"]], r.sort_ro("bar", get: ["foo:*:a", "foo:*:b"])
    end
  end

  def test_sort_ro_with_by
    target_version "7.0.0" do
      r.rpush("bar", %w[1 2 3])
      r.set("weight_1", "30")
      r.set("weight_2", "20")
      r.set("weight_3", "10")

      assert_equal %w[3 2 1], r.sort_ro("bar", by: "weight_*")
      assert_equal [["3", "10"], ["2", "20"], ["1", "30"]], r.sort_ro("bar", by: "weight_*", get: ["#", "weight_*"])
    end
  end

  def test_sort_ro_on_missing_key
    target_version "7.0.0" do
      assert_equal [], r.sort_ro("missing")
    end
  end

  def test_sort_ro_has_no_store_option
    assert_raises(ArgumentError) { r.sort_ro("bar", store: "baz") }
  end

  def test_sort_ro_in_pipeline
    target_version "7.0.0" do
      r.set("foo:1:a", "s1a")
      r.set("foo:1:b", "s1b")
      r.set("foo:2:a", "s2a")
      r.set("foo:2:b", "s2b")
      r.rpush("bar", %w[2 1])

      plain, sliced = r.pipelined do |pipe|
        pipe.sort_ro("bar")
        pipe.sort_ro("bar", get: ["foo:*:a", "foo:*:b"])
      end

      assert_equal %w[1 2], plain
      assert_equal [["s1a", "s1b"], ["s2a", "s2b"]], sliced
    end
  end
end
