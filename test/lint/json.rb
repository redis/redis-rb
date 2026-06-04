# frozen_string_literal: true

module Lint
  module Json
    def setup
      super
      omit_unless_module("ReJSON")
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
  end
end
