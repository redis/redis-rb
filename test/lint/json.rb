# frozen_string_literal: true

module Lint
  module Json
    def setup
      super
      require_module("ReJSON")
    end

    def test_set_returns_ok
      assert_equal "OK", r.json_set("doc", "$", { "a" => 1 })
    end

    def test_set_with_raw_returns_ok
      assert_equal "OK", r.json_set("doc", "$", '{"a":1}', raw: true)
    end

    def test_set_and_get_whole_document
      doc = { "a" => 1, "nested" => { "b" => 2 } }

      r.json_set("doc", "$", doc)

      assert_equal doc, r.json_get("doc")
    end

    def test_set_and_get_with_array_value
      value = [1, 2, ["a", "b"]]

      r.json_set("doc", "$", value)

      assert_equal value, r.json_get("doc")
    end

    def test_set_at_nested_path
      r.json_set("doc", "$", { "a" => 1, "nested" => { "b" => 2 } })

      r.json_set("doc", "$.nested.b", 99)

      assert_equal [99], r.json_get("doc", "$.nested.b")
    end

    def test_get_single_path_returns_array_of_matches
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [1], r.json_get("doc", "$.a")
    end

    def test_get_multiple_paths_returns_hash_keyed_by_path
      r.json_set("doc", "$", { "a" => 1, "nested" => { "b" => 2 } })

      assert_equal({ "$.a" => [1], "$.nested.b" => [2] }, r.json_get("doc", "$.a", "$.nested.b"))
    end

    def test_get_missing_key_returns_nil
      assert_nil r.json_get("missing")
    end

    def test_set_with_nx_on_existing_path_returns_false
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal false, r.json_set("doc", "$.a", 2, nx: true)
      assert_equal [1], r.json_get("doc", "$.a")
    end

    def test_set_with_nx_on_missing_path_returns_true
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal true, r.json_set("doc", "$.b", 2, nx: true)
      assert_equal [2], r.json_get("doc", "$.b")
    end

    def test_set_with_xx_on_missing_path_returns_false
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal false, r.json_set("doc", "$.b", 2, xx: true)
      assert_nil r.json_get("doc", "$.b").first
    end

    def test_set_with_both_nx_and_xx_raises
      assert_raises(ArgumentError) { r.json_set("doc", "$", { "a" => 1 }, nx: true, xx: true) }
    end

    def test_set_with_raw_passes_encoded_json_through
      r.json_set("doc", "$", '{"a":1,"b":[2,3]}', raw: true)

      assert_equal({ "a" => 1, "b" => [2, 3] }, r.json_get("doc"))
    end

    def test_set_without_raw_does_not_double_encode_a_string
      # A plain Ruby string is a JSON value: it must be stored as a JSON string, not as raw JSON.
      r.json_set("doc", "$", "hello")

      assert_equal "hello", r.json_get("doc")
    end

    def test_get_with_raw_returns_unparsed_json_string
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal '[{"a":1}]', r.json_get("doc", "$", raw: true)
    end

    def test_get_with_raw_on_missing_key_returns_nil
      assert_nil r.json_get("missing", raw: true)
    end

    def test_mget_returns_one_value_per_key_in_order
      r.json_set("doc1", "$", { "a" => 1 })
      r.json_set("doc2", "$", { "a" => 2 })

      assert_equal [[1], [2], nil], r.json_mget("doc1", "doc2", "missing", "$.a")
    end

    def test_mget_accepts_an_array_of_keys
      r.json_set("doc1", "$", { "a" => 1 })
      r.json_set("doc2", "$", { "a" => 2 })

      # A nested array of keys must behave the same as splatted keys (matches #mget).
      assert_equal [[1], [2]], r.json_mget(["doc1", "doc2"], "$.a")
    end

    def test_mget_returns_empty_match_for_missing_path
      r.json_set("doc1", "$", { "a" => 1 })

      assert_equal [[]], r.json_mget("doc1", "$.nope")
    end

    def test_mget_with_raw_returns_unparsed_strings
      r.json_set("doc1", "$", { "a" => 1 })

      assert_equal ["[1]"], r.json_mget("doc1", "$.a", raw: true)
    end

    def test_del_with_path_deletes_matching_values
      r.json_set("doc", "$", { "a" => 1, "nested" => { "a" => 2, "b" => 3 } })

      assert_equal 2, r.json_del("doc", "$..a")
      assert_equal({ "nested" => { "b" => 3 } }, r.json_get("doc"))
    end

    def test_del_without_path_removes_the_key
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal 1, r.json_del("doc")
      assert_nil r.json_get("doc")
    end

    def test_del_on_missing_path_returns_zero
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal 0, r.json_del("doc", "$.nope")
    end

    def test_forget_deletes_like_del
      r.json_set("doc", "$", { "a" => 1, "b" => 2 })

      assert_equal 1, r.json_forget("doc", "$.a")
      assert_equal({ "b" => 2 }, r.json_get("doc"))
    end

    def test_clear_empties_containers_and_zeroes_numbers
      r.json_set("doc", "$", { "obj" => { "a" => 1 }, "arr" => [1, 2, 3], "int" => 42, "str" => "foo" })

      assert_equal 3, r.json_clear("doc", "$.*")
      assert_equal({ "obj" => {}, "arr" => [], "int" => 0, "str" => "foo" }, r.json_get("doc"))
    end

    def test_clear_on_already_cleared_value_returns_zero
      r.json_set("doc", "$", { "arr" => [] })

      assert_equal 0, r.json_clear("doc", "$.arr")
    end

    def test_merge_creates_key_at_root
      assert_equal "OK", r.json_merge("doc", "$", { "a" => 1 })
      assert_equal({ "a" => 1 }, r.json_get("doc"))
    end

    def test_merge_adds_and_updates_fields
      r.json_set("doc", "$", { "a" => 2 })

      assert_equal "OK", r.json_merge("doc", "$.b", 8)
      r.json_merge("doc", "$.a", 3)
      assert_equal({ "a" => 3, "b" => 8 }, r.json_get("doc"))
    end

    def test_merge_with_null_deletes_a_field
      r.json_set("doc", "$", { "a" => 2, "b" => 3 })

      r.json_merge("doc", "$", { "a" => nil })
      assert_equal({ "b" => 3 }, r.json_get("doc"))
    end

    def test_merge_replaces_an_existing_array
      r.json_set("doc", "$", { "a" => [2, 4, 6] })

      r.json_merge("doc", "$.a", [10, 12])
      assert_equal({ "a" => [10, 12] }, r.json_get("doc"))
    end

    def test_merge_with_raw_value
      r.json_set("doc", "$", { "a" => 1 })

      r.json_merge("doc", "$.b", "[1,2]", raw: true)
      assert_equal({ "a" => 1, "b" => [1, 2] }, r.json_get("doc"))
    end

    def test_arrappend_appends_values_and_returns_new_length
      r.json_set("doc", "$", { "colors" => ["black", "silver"] })

      assert_equal [4], r.json_arrappend("doc", "$.colors", "blue", "red")
      assert_equal [["black", "silver", "blue", "red"]], r.json_get("doc", "$.colors")
    end

    def test_arrappend_with_raw_values
      r.json_set("doc", "$", { "a" => [1] })

      assert_equal [3], r.json_arrappend("doc", "$.a", "2", "3", raw: true)
      assert_equal [[1, 2, 3]], r.json_get("doc", "$.a")
    end

    def test_arrappend_on_non_array_match_returns_nil
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [nil], r.json_arrappend("doc", "$.a", "x")
    end

    def test_arrindex_finds_a_scalar
      r.json_set("doc", "$", { "colors" => ["black", "silver", "blue"] })

      assert_equal [1], r.json_arrindex("doc", "$.colors", "silver")
    end

    def test_arrindex_returns_minus_one_when_absent
      r.json_set("doc", "$", { "colors" => ["black"] })

      assert_equal [-1], r.json_arrindex("doc", "$.colors", "gold")
    end

    def test_arrindex_with_start_restricts_the_search
      r.json_set("doc", "$", { "colors" => ["black", "silver", "black"] })

      assert_equal [2], r.json_arrindex("doc", "$.colors", "black", start: 1)
    end

    def test_arrinsert_inserts_values_and_returns_new_length
      r.json_set("doc", "$", { "colors" => ["black", "blue"] })

      assert_equal [4], r.json_arrinsert("doc", "$.colors", 1, "silver", "gold")
      assert_equal [["black", "silver", "gold", "blue"]], r.json_get("doc", "$.colors")
    end

    def test_arrinsert_with_a_negative_index
      r.json_set("doc", "$", { "c" => [1, 2, 3] })

      r.json_arrinsert("doc", "$.c", -1, 9)
      assert_equal [[1, 2, 9, 3]], r.json_get("doc", "$.c")
    end

    def test_arrlen_returns_the_length
      r.json_set("doc", "$", { "colors" => %w[a b c] })

      assert_equal [3], r.json_arrlen("doc", "$.colors")
    end

    def test_arrlen_on_missing_path_returns_no_matches
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [], r.json_arrlen("doc", "$.nope")
    end

    def test_arrlen_on_non_array_match_returns_nil
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [nil], r.json_arrlen("doc", "$.a")
    end

    def test_arrpop_without_index_pops_the_last_element
      r.json_set("doc", "$", { "c" => [1, 2, 3] })

      assert_equal [3], r.json_arrpop("doc", "$.c")
      assert_equal [[1, 2]], r.json_get("doc", "$.c")
    end

    def test_arrpop_with_an_index
      r.json_set("doc", "$", { "c" => %w[x y z] })

      assert_equal ["x"], r.json_arrpop("doc", "$.c", 0)
    end

    def test_arrpop_with_raw_returns_unparsed_strings
      r.json_set("doc", "$", { "c" => %w[x y] })

      assert_equal ['"y"'], r.json_arrpop("doc", "$.c", raw: true)
    end

    def test_arrpop_with_index_but_no_path_raises
      assert_raises(ArgumentError) { r.json_arrpop("doc", nil, 0) }
    end

    def test_arrtrim_keeps_the_range_and_returns_new_length
      r.json_set("doc", "$", { "c" => [1, 2, 3, 4, 5] })

      assert_equal [3], r.json_arrtrim("doc", "$.c", 1, 3)
      assert_equal [[2, 3, 4]], r.json_get("doc", "$.c")
    end

    # A legacy path (".foo") returns a single scalar reply rather than the JSONPath array form.

    def test_arrappend_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "colors" => ["black"] })

      assert_equal 2, r.json_arrappend("doc", ".colors", "silver")
    end

    def test_arrindex_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "colors" => ["black", "silver"] })

      assert_equal 1, r.json_arrindex("doc", ".colors", "silver")
    end

    def test_arrinsert_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "colors" => ["black", "blue"] })

      assert_equal 3, r.json_arrinsert("doc", ".colors", 1, "silver")
    end

    def test_arrlen_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "colors" => %w[a b c] })

      assert_equal 3, r.json_arrlen("doc", ".colors")
    end

    def test_arrpop_with_legacy_path_returns_a_single_value
      r.json_set("doc", "$", { "colors" => ["black", "silver"] })

      assert_equal "silver", r.json_arrpop("doc", ".colors")
    end

    def test_arrtrim_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "c" => [1, 2, 3, 4] })

      assert_equal 2, r.json_arrtrim("doc", ".c", 1, 2)
    end

    def test_numincrby_with_jsonpath_returns_an_array
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [3], r.json_numincrby("doc", "$.a", 2)
    end

    def test_numincrby_with_legacy_path_returns_a_scalar
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal 3, r.json_numincrby("doc", ".a", 2)
    end

    def test_numincrby_increments_a_float
      r.json_set("doc", "$", { "a" => 2.5 })

      assert_equal [3.0], r.json_numincrby("doc", "$.a", 0.5)
    end

    def test_numincrby_on_non_numeric_match_yields_nil
      r.json_set("doc", "$", { "a" => "x" })

      assert_equal [nil], r.json_numincrby("doc", "$.a", 1)
    end

    def test_type_with_jsonpath_returns_an_array_of_type_strings
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal ["integer"], r.json_type("doc", "$.a")
    end

    def test_type_with_legacy_path_returns_a_single_type_string
      r.json_set("doc", "$", { "s" => "x" })

      assert_equal "string", r.json_type("doc", ".s")
    end

    def test_type_without_a_path_returns_the_root_type
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal "object", r.json_type("doc")
    end

    def test_type_on_a_missing_path_returns_no_matches
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [], r.json_type("doc", "$.zzz")
    end

    def test_objkeys_with_jsonpath_returns_an_array_of_key_arrays
      r.json_set("doc", "$", { "obj" => { "b" => 2, "c" => 1 } })

      assert_equal [%w[b c]], r.json_objkeys("doc", "$.obj")
    end

    def test_objkeys_with_legacy_path_returns_a_key_array
      r.json_set("doc", "$", { "obj" => { "b" => 2, "c" => 1 } })

      assert_equal %w[b c], r.json_objkeys("doc", ".obj")
    end

    def test_objkeys_on_non_object_match_yields_nil
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [nil], r.json_objkeys("doc", "$.a")
    end

    def test_objlen_with_jsonpath_returns_an_array
      r.json_set("doc", "$", { "obj" => { "b" => 2, "c" => 1 } })

      assert_equal [2], r.json_objlen("doc", "$.obj")
    end

    def test_objlen_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "obj" => { "b" => 2, "c" => 1 } })

      assert_equal 2, r.json_objlen("doc", ".obj")
    end

    def test_strlen_with_jsonpath_returns_an_array
      r.json_set("doc", "$", { "s" => "foo" })

      assert_equal [3], r.json_strlen("doc", "$.s")
    end

    def test_strlen_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "s" => "foo" })

      assert_equal 3, r.json_strlen("doc", ".s")
    end

    def test_strappend_appends_and_returns_new_length
      r.json_set("doc", "$", { "s" => "foo" })

      assert_equal [6], r.json_strappend("doc", "$.s", "bar")
      assert_equal ["foobar"], r.json_get("doc", "$.s")
    end

    def test_strappend_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "s" => "foo" })

      assert_equal 6, r.json_strappend("doc", ".s", "bar")
    end

    def test_strappend_with_raw_value
      r.json_set("doc", "$", { "s" => "foo" })

      assert_equal [4], r.json_strappend("doc", "$.s", '"X"', raw: true)
      assert_equal ["fooX"], r.json_get("doc", "$.s")
    end

    def test_toggle_flips_a_boolean
      r.json_set("doc", "$", { "flag" => true })

      assert_equal [0], r.json_toggle("doc", "$.flag")
      assert_equal [1], r.json_toggle("doc", "$.flag")
    end

    def test_toggle_on_non_boolean_match_yields_nil
      r.json_set("doc", "$", { "a" => 1 })

      assert_equal [nil], r.json_toggle("doc", "$.a")
    end

    def test_debug_memory_without_a_path_returns_an_integer
      r.json_set("doc", "$", { "a" => 1, "obj" => { "b" => 2 } })

      assert_kind_of Integer, r.json_debug_memory("doc")
    end

    def test_debug_memory_with_jsonpath_returns_an_array
      r.json_set("doc", "$", { "obj" => { "b" => 2 } })

      result = r.json_debug_memory("doc", "$.obj")
      assert_kind_of Array, result
      assert_kind_of Integer, result.first
    end

    def test_debug_memory_with_legacy_path_returns_an_integer
      r.json_set("doc", "$", { "obj" => { "b" => 2 } })

      assert_kind_of Integer, r.json_debug_memory("doc", ".obj")
    end

    def test_debug_memory_on_missing_key_returns_zero
      assert_equal 0, r.json_debug_memory("missing")
    end
  end
end
