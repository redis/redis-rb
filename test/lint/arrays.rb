# frozen_string_literal: true

module Lint
  module Arrays
    def test_arset
      target_version "8.8" do
        assert_equal 1, r.arset("foo", 0, "s1")
        assert_equal 1, r.arset("foo", 1, "s2")
      end
    end

    def test_arset_with_multiple_values
      target_version "8.8" do
        assert_equal 3, r.arset("foo", 0, "s1", "s2", "s3")
      end
    end

    def test_arset_counts_only_new_slots
      target_version "8.8" do
        assert_equal 2, r.arset("foo", 0, "s1", "s2")
        # Overwriting existing slots fills no new ones.
        assert_equal 0, r.arset("foo", 1, "s2b")
        # One overwrite (index 1) plus one new slot (index 2).
        assert_equal 1, r.arset("foo", 1, "s2c", "s3")
      end
    end

    def test_arset_past_the_end_leaves_a_gap
      target_version "8.8" do
        assert_equal 1, r.arset("foo", 0, "s1")
        assert_equal 1, r.arset("foo", 3, "s4")
      end
    end

    def test_arset_with_negative_index
      target_version "8.8" do
        error = assert_raises(Redis::CommandError) { r.arset("foo", -1, "s1") }
        assert_match(/invalid array index/i, error.message)
      end
    end

    def test_arset_coerces_index
      target_version "8.8" do
        assert_equal 1, r.arset("foo", "0", "s1")
        assert_raises(TypeError) { r.arset("foo", nil, "s1") }
        assert_raises(ArgumentError) { r.arset("foo", "first", "s1") }
      end
    end

    def test_arget
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2")

        assert_equal "s1", r.arget("foo", 0)
        assert_equal "s2", r.arget("foo", 1)
      end
    end

    def test_arget_on_missing_key
      target_version "8.8" do
        assert_nil r.arget("foo", 0)
      end
    end

    def test_arget_on_missing_index
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        # Past the end of the array.
        assert_nil r.arget("foo", 9)

        # An empty slot inside the array (gap left by a sparse ARSET).
        r.arset("foo", 2, "s3")

        assert_nil r.arget("foo", 1)
      end
    end

    def test_arget_with_negative_index
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        error = assert_raises(Redis::CommandError) { r.arget("foo", -1) }
        assert_match(/invalid array index/i, error.message)
      end
    end

    def test_armset
      target_version "8.8" do
        assert_equal 2, r.armset("foo", 0, "s1", 5, "s6")
        assert_equal "s1", r.arget("foo", 0)
        assert_equal "s6", r.arget("foo", 5)
      end
    end

    def test_armset_counts_only_new_slots
      target_version "8.8" do
        r.armset("foo", 0, "s1", 5, "s6")

        assert_equal 1, r.armset("foo", 0, "s1b", 1, "s2")
      end
    end

    def test_armset_with_hash
      target_version "8.8" do
        assert_equal 2, r.armset("foo", { 0 => "s1", 5 => "s6" })
        assert_equal "s6", r.arget("foo", 5)
      end
    end

    def test_armset_with_arrays
      target_version "8.8" do
        # A single flat array and one-array-per-pair are both accepted,
        # consistent with armget/ardel/ardelrange flattening one level.
        assert_equal 2, r.armset("foo", [0, "s1", 5, "s6"])
        assert_equal 2, r.armset("bar", [0, "s1"], [5, "s6"])
        assert_equal "s6", r.arget("bar", 5)
      end
    end

    def test_armset_with_invalid_args
      target_version "8.8" do
        assert_raises(ArgumentError) { r.armset("foo") }
        assert_raises(ArgumentError) { r.armset("foo", 0, "s1", 1) }
      end
    end

    def test_armget
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2", "s3")

        assert_equal %w[s3 s1], r.armget("foo", 2, 0)
      end
    end

    def test_armget_on_missing_key_and_indices
      target_version "8.8" do
        assert_equal [nil, nil], r.armget("foo", 0, 1)

        r.arset("foo", 0, "s1")

        assert_equal ["s1", nil], r.armget("foo", 0, 9)
      end
    end

    def test_argetrange
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        r.arset("foo", 2, "s3")

        assert_equal ["s1", nil, "s3"], r.argetrange("foo", 0, 2)
      end
    end

    def test_argetrange_reversed
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2", "s3")

        assert_equal %w[s3 s2 s1], r.argetrange("foo", 2, 0)
      end
    end

    def test_argetrange_on_missing_key
      target_version "8.8" do
        assert_equal [nil, nil, nil], r.argetrange("foo", 0, 2)
      end
    end

    def test_arlen
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        r.arset("foo", 3, "s4")

        assert_equal 4, r.arlen("foo")
        assert_equal 0, r.arlen("bar")
      end
    end

    def test_arcount
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        r.arset("foo", 3, "s4")

        assert_equal 2, r.arcount("foo")
        assert_equal 0, r.arcount("bar")
      end
    end

    def test_ardel
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2", "s3")

        assert_equal 2, r.ardel("foo", 0, 2)
        assert_nil r.arget("foo", 0)
        assert_equal "s2", r.arget("foo", 1)
      end
    end

    def test_ardel_on_missing_index
      target_version "8.8" do
        r.arset("foo", 0, "s1")

        assert_equal 0, r.ardel("foo", 9)
      end
    end

    def test_ardelrange
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2", "s3", "s4", "s5", "s6")

        assert_equal 4, r.ardelrange("foo", 0, 1, 4, 5)
        assert_equal 2, r.arcount("foo")
      end
    end

    def test_ardelrange_with_reversed_range
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2", "s3")

        assert_equal 2, r.ardelrange("foo", 1, 0)
      end
    end

    def test_ardelrange_on_missing_key_and_invalid_args
      target_version "8.8" do
        assert_equal 0, r.ardelrange("foo", 0, 9)
        assert_raises(ArgumentError) { r.ardelrange("foo") }
        assert_raises(ArgumentError) { r.ardelrange("foo", 0, 1, 2) }
      end
    end

    def test_arinsert
      target_version "8.8" do
        assert_equal 2, r.arinsert("foo", "s1", "s2", "s3")
        assert_equal %w[s1 s2 s3], r.argetrange("foo", 0, 2)
        assert_equal 3, r.arinsert("foo", "s4")
      end
    end

    def test_arseek_repositions_the_insert_cursor
      target_version "8.8" do
        r.arinsert("foo", "s1", "s2", "s3")

        assert_equal true, r.arseek("foo", 1)
        assert_equal 1, r.arnext("foo")
        assert_equal 1, r.arinsert("foo", "s2b")
        assert_equal "s2b", r.arget("foo", 1)
      end
    end

    def test_arseek_on_missing_key
      target_version "8.8" do
        assert_equal false, r.arseek("foo", 1)
      end
    end

    def test_arnext
      target_version "8.8" do
        assert_equal 0, r.arnext("foo")

        r.arinsert("foo", "s1", "s2")

        assert_equal 2, r.arnext("foo")
      end
    end

    def test_arlastitems
      target_version "8.8" do
        r.arinsert("foo", "s1", "s2", "s3", "s4")

        assert_equal %w[s3 s4], r.arlastitems("foo", 2)
      end
    end

    def test_arlastitems_reversed
      target_version "8.8" do
        r.arinsert("foo", "s1", "s2", "s3", "s4")

        assert_equal %w[s4 s3], r.arlastitems("foo", 2, rev: true)
      end
    end

    def test_arlastitems_with_count_greater_than_size
      target_version "8.8" do
        r.arinsert("foo", "s1", "s2")

        assert_equal %w[s1 s2], r.arlastitems("foo", 99)
      end
    end

    def test_arring
      target_version "8.8" do
        assert_equal 1, r.arring("foo", 3, "s1", "s2")
        assert_equal %w[s1 s2], r.argetrange("foo", 0, 1)
      end
    end

    def test_arring_wraps_around
      target_version "8.8" do
        r.arring("foo", 3, "s1", "s2", "s3")

        assert_equal 0, r.arring("foo", 3, "s4")
        assert_equal %w[s4 s2 s3], r.argetrange("foo", 0, 2)
      end
    end

    def test_arring_truncates_when_size_shrinks
      target_version "8.8" do
        r.arring("foo", 5, "s1", "s2", "s3", "s4")
        r.arring("foo", 2, "s5")

        assert_equal 2, r.arlen("foo")
      end
    end

    def test_arscan
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        r.arset("foo", 3, "s4")

        assert_equal [[0, "s1"], [3, "s4"]], r.arscan("foo", 0, 9)
      end
    end

    def test_arscan_reversed
      target_version "8.8" do
        r.arset("foo", 0, "s1")
        r.arset("foo", 3, "s4")

        assert_equal [[3, "s4"], [0, "s1"]], r.arscan("foo", 9, 0)
      end
    end

    def test_arscan_with_limit
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2", "s3")

        assert_equal [[0, "s1"], [1, "s2"]], r.arscan("foo", 0, 9, limit: 2)
      end
    end

    def test_arscan_on_missing_key
      target_version "8.8" do
        assert_equal [], r.arscan("foo", 0, 9)
      end
    end

    def test_zero_limit_is_sent_and_rejected_by_the_server
      target_version "8.8" do
        r.arset("foo", 0, "s1")

        # 0 is truthy in Ruby, so LIMIT 0 goes on the wire; the server
        # defines it as invalid rather than "no results".
        error = assert_raises(Redis::CommandError) { r.arscan("foo", 0, 9, limit: 0) }
        assert_match(/LIMIT must be positive/i, error.message)
        assert_raises(Redis::CommandError) { r.argrep("foo", 0, 9, match: "s", limit: 0) }
      end
    end

    def test_argrep_with_exact_predicate
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana", "cherry")

        assert_equal [0], r.argrep("foo", 0, 9, exact: "apple")
      end
    end

    def test_argrep_with_match_predicate
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana", "cherry")

        assert_equal [1], r.argrep("foo", 0, 9, match: "an")
      end
    end

    def test_argrep_with_glob_predicate
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana", "cherry")

        assert_equal [0], r.argrep("foo", 0, 9, glob: "a*e")
      end
    end

    def test_argrep_with_re_predicate
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana", "cherry")

        assert_equal [0], r.argrep("foo", 0, 9, re: "^ap+le$")
      end
    end

    def test_argrep_with_nocase
      target_version "8.8" do
        r.arset("foo", 0, "apple", "APPLE")

        assert_equal [0, 1], r.argrep("foo", 0, 9, exact: "Apple", nocase: true)
      end
    end

    def test_argrep_with_values
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana")

        assert_equal [[0, "apple"]], r.argrep("foo", 0, 9, exact: "apple", with_values: true)
      end
    end

    def test_argrep_with_limit
      target_version "8.8" do
        r.arset("foo", 0, "s", "s", "s")

        assert_equal [0, 1], r.argrep("foo", 0, 9, exact: "s", limit: 2)
      end
    end

    def test_argrep_with_multiple_predicates
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana", "cherry")

        # OR is the server default: either predicate matches.
        assert_equal [0, 1], r.argrep("foo", 0, 9, exact: ["apple", "banana"], logic: :or)
        # AND: every predicate must match the same element.
        assert_equal [0], r.argrep("foo", 0, 9, match: %w[a p], logic: :and)
        assert_raises(ArgumentError) { r.argrep("foo", 0, 9, match: "a", logic: :xor) }
      end
    end

    def test_argrep_reversed_and_missing_key
      target_version "8.8" do
        assert_equal [], r.argrep("foo", 0, 9, match: "a")

        r.arset("foo", 0, "apple", "avocado")

        assert_equal [1, 0], r.argrep("foo", 9, 0, match: "a")
      end
    end

    def test_argrep_with_full_range_sentinels
      target_version "8.8" do
        r.arset("foo", 0, "apple", "banana")

        assert_equal [0, 1], r.argrep("foo", "-", "+", match: "a")
        # Other bounds must still be numeric and fail fast client-side.
        assert_raises(ArgumentError) { r.argrep("foo", "first", "+", match: "a") }
      end
    end

    def test_arop_numeric_operations
      target_version "8.8" do
        r.arset("foo", 0, "1", "2", "3")

        assert_equal 6.0, r.arop("foo", 0, 2, :sum)
        assert_equal 1.0, r.arop("foo", 0, 2, :min)
        assert_equal 3.0, r.arop("foo", 0, 2, :max)
      end
    end

    def test_arop_bitwise_operations
      target_version "8.8" do
        r.arset("foo", 0, "1", "2", "3")

        assert_equal 0, r.arop("foo", 0, 2, :and)
        assert_equal 3, r.arop("foo", 0, 2, :or)
        assert_equal 0, r.arop("foo", 0, 2, :xor)
      end
    end

    def test_arop_match_and_used
      target_version "8.8" do
        r.arset("foo", 0, "1", "2", "2")

        assert_equal 2, r.arop("foo", 0, 2, :match, value: "2")
        assert_equal 3, r.arop("foo", 0, 2, :used)
        assert_raises(ArgumentError) { r.arop("foo", 0, 2, :match) }
      end
    end

    def test_arop_skips_non_numeric_values
      target_version "8.8" do
        r.arset("foo", 0, "1", "abc", "3")

        assert_equal 4.0, r.arop("foo", 0, 2, :sum)
      end
    end

    def test_arop_on_empty_range
      target_version "8.8" do
        r.arset("foo", 0, "1")

        assert_nil r.arop("foo", 5, 9, :sum)
      end
    end

    def test_arinfo
      target_version "8.8" do
        r.arset("foo", 0, "s1", "s2")

        info = r.arinfo("foo")

        assert_kind_of Hash, info
        assert_equal 2, info["count"]
        assert_equal 2, info["len"]
        assert info.key?("next-insert-index")
        assert info.key?("slices")
      end
    end

    def test_arinfo_full
      target_version "8.8" do
        r.arset("foo", 0, "s1")

        info = r.arinfo("foo", full: true)

        assert info.key?("dense-slices")
        assert info.key?("sparse-slices")
        # The avg-* statistics are doubles under RESP3 but bulk strings under
        # RESP2; HashifyArrayInfo converges both on Float.
        %w[avg-dense-size avg-dense-fill avg-sparse-size].each do |field|
          assert_kind_of Float, info[field], "expected #{field} to be a Float"
        end
      end
    end

    def test_arinfo_on_missing_key
      target_version "8.8" do
        error = assert_raises(Redis::CommandError) { r.arinfo("foo") }
        assert_match(/no such key/i, error.message)
      end
    end
  end
end
