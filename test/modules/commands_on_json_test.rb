# frozen_string_literal: true

require "helper"

class TestCommandsOnJson < Minitest::Test
  include Helper::Modules
  include Lint::Json

  def test_get_in_pipeline_returns_parsed_object
    r.json_set("doc", "$", { "a" => 1 })

    result = r.pipelined do |pipe|
      pipe.json_get("doc")
    end

    assert_equal({ "a" => 1 }, result.first)
  end

  def test_set_with_nx_in_pipeline_resolves_to_boolean
    result = r.pipelined do |pipe|
      pipe.json_set("doc", "$", { "a" => 1 }, nx: true)
    end

    assert_equal true, result.first
  end

  # JSON.MSET is multi-key and atomic, so it is only exercised against a single instance here;
  # Redis::Distributed cannot support it (see test/distributed/commands_on_json_test.rb).
  def test_mset_sets_multiple_documents
    assert_equal "OK", r.json_mset("doc1", "$", { "a" => 1 }, "doc2", "$", { "b" => 2 })
    assert_equal({ "a" => 1 }, r.json_get("doc1"))
    assert_equal({ "b" => 2 }, r.json_get("doc2"))
  end

  def test_mset_updates_a_nested_path
    r.json_set("doc", "$", { "f" => { "a" => 1 } })

    assert_equal "OK", r.json_mset("doc", "$.f.a", 3)
    assert_equal({ "f" => { "a" => 3 } }, r.json_get("doc"))
  end

  def test_mset_with_raw_values
    assert_equal "OK", r.json_mset("doc1", "$", '{"a":1}', "doc2", "$", '{"b":2}', raw: true)
    assert_equal({ "a" => 1 }, r.json_get("doc1"))
    assert_equal({ "b" => 2 }, r.json_get("doc2"))
  end

  def test_mset_with_incomplete_triplet_raises
    assert_raises(ArgumentError) { r.json_mset("doc1", "$") }
  end

  def test_arrpop_in_pipeline_returns_parsed_value
    r.json_set("doc", "$", { "c" => [1, 2, 3] })

    result = r.pipelined do |pipe|
      pipe.json_arrpop("doc", "$.c")
    end

    assert_equal [3], result.first
  end

  # JSON.NUMINCRBY and JSON.TYPE reply differently under RESP2 and RESP3. The client is pinned to
  # RESP2 today, so these unit-test the reshapes directly with both protocol shapes to prove they
  # normalize to the same value (guarding the result when RESP3 is eventually enabled).

  def test_numincrby_reshape_is_protocol_compatible
    norm = Redis::Commands::Json::NumincrbyNormalize

    assert_equal [3, 4], norm.call("[3,4]", true)  # RESP2 JSONPath (JSON string)
    assert_equal [3, 4], norm.call([3, 4], true)   # RESP3 JSONPath (native array)
    assert_equal 3, norm.call("3", false)          # RESP2 legacy (JSON string)
    assert_equal 3, norm.call([3], false)          # RESP3 legacy (wrapped array)
    assert_equal [nil, 4], norm.call("[null,4]", true)
    assert_nil norm.call(nil, true)
  end

  def test_type_reshape_is_protocol_compatible
    norm = Redis::Commands::Json::TypeNormalize

    assert_equal ["integer"], norm.call(["integer"], true)             # RESP2 JSONPath
    assert_equal ["integer"], norm.call([["integer"]], true)           # RESP3 JSONPath
    assert_equal %w[integer boolean], norm.call(%w[integer boolean], true)          # RESP2 multi
    assert_equal %w[integer boolean], norm.call([["integer"], ["boolean"]], true)   # RESP3 multi
    assert_equal "string", norm.call("string", false)                  # RESP2 legacy
    assert_equal "string", norm.call(["string"], false)                # RESP3 legacy
    assert_nil norm.call(nil, true)
  end
end
