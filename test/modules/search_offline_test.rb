# frozen_string_literal: true

# Offline unit tests for the Query Engine builder/DSL classes and the reply-reshaping layer.
# These do not touch a Redis server, so they run regardless of which modules are loaded.
require "minitest/autorun"
require "redis"

class TestSearchOffline < Minitest::Test
  include Redis::Commands::Search

  RP = Redis::Commands::Search::ResultParser

  # ---- Schema / Field building -------------------------------------------------------------

  def test_schema_definition_fields
    schema = Schema.build do
      text_field "title", weight: 5.0, no_stem: true
      text_field "body"
      numeric_field "price", sortable: true
      geo_field "location"
      tag_field "tags", separator: ",", case_sensitive: true
    end

    assert_equal 5, schema.fields.size
    assert_equal "title", schema.fields[0].name
    assert_equal :text, schema.fields[0].type
    assert_equal :numeric, schema.fields[2].type
    assert_equal :geo, schema.fields[3].type
    assert_equal :tag, schema.fields[4].type
  end

  def test_schema_to_args_starts_with_schema_keyword
    schema = Schema.build { text_field :title }
    args = schema.to_args
    assert_equal "SCHEMA", args.first
    assert_includes args, "title"
    assert_includes args, "TEXT"
  end

  def test_text_field_supports_index_missing
    # text_field must accept index_missing (TextField#to_args emits INDEXMISSING).
    schema = Schema.build { text_field :title, index_missing: true }
    assert_includes schema.fields.first.to_args, "INDEXMISSING"
  end

  def test_svs_vamana_vector_field_to_args
    schema = Schema.build do
      vector_field :v, "SVS-VAMANA", type: "FLOAT32", dim: 128, distance_metric: "COSINE"
    end
    args = schema.fields.first.to_args
    assert_equal "v", args[0]
    assert_equal "VECTOR", args[1]
    assert_equal "SVS-VAMANA", args[2]
    assert_includes args, "TYPE"
    assert_includes args, "FLOAT32"
    assert_includes args, "DIM"
    assert_includes args, "128"
  end

  def test_vector_field_block_dsl_upcases_values
    # The block DSL (add_attribute) must normalize values the same as the kwargs form, so
    # FT.CREATE receives canonical uppercase tokens (e.g. FLOAT32/COSINE, not float32/cosine).
    schema = Schema.build do
      vector_field(:v, "HNSW") do
        type "float32"
        dim 4
        distance_metric "cosine"
      end
    end
    args = schema.fields.first.to_args
    assert_includes args, "FLOAT32"
    assert_includes args, "COSINE"
    refute_includes args, "float32"
    refute_includes args, "cosine"
  end

  def test_vector_field_rejects_unknown_algorithm
    assert_raises(ArgumentError) do
      Redis::Commands::Search::VectorField.new("v", "BOGUS", { "TYPE" => "FLOAT32" })
    end
  end

  def test_vector_field_rejects_sortable
    assert_raises(Redis::CommandError) do
      Schema.build do
        vector_field :v, "FLAT", type: "FLOAT32", dim: 4, distance_metric: "L2", sortable: true
      end
    end
  end

  # ---- Index definition --------------------------------------------------------------------

  def test_index_definition_on_json
    definition = IndexDefinition.new(prefix: ["bicycle:"], index_type: IndexType::JSON)
    assert_equal ["ON", "JSON", "PREFIX", 1, "bicycle:"], definition.args.first(5)
  end

  def test_index_definition_on_hash
    definition = IndexDefinition.new(prefix: ["doc:"], index_type: IndexType::HASH)
    assert_equal %w[ON HASH], definition.args.first(2)
  end

  def test_index_definition_rejects_unknown_type
    assert_raises(ArgumentError) { IndexDefinition.new(index_type: "bogus") }
  end

  def test_index_definition_exposes_prefixes
    assert_equal ["bicycle:"], IndexDefinition.new(prefix: ["bicycle:"]).prefixes
    assert_empty IndexDefinition.new.prefixes
  end

  def test_index_definition_prefix_is_nil_safe
    # An explicit prefix: nil must not raise and must emit no PREFIX clause.
    definition = IndexDefinition.new(prefix: nil)
    assert_empty definition.prefixes
    refute_includes definition.args, "PREFIX"
  end

  def test_index_definition_accepts_single_string_prefix
    # A lone String prefix is wrapped into a one-element list (PREFIX 1 <prefix>), not split.
    definition = IndexDefinition.new(prefix: "bicycle:")
    assert_equal ["bicycle:"], definition.prefixes
    assert_equal ["PREFIX", 1, "bicycle:"], definition.args.first(3)
  end

  def test_index_key_prefix_derivation
    # A single definition prefix is used verbatim; the keyword form appends ":".
    defn = IndexDefinition.new(prefix: ["bicycle:"])
    assert_equal "bicycle:", Index.key_prefix(nil, defn)
    assert_equal "doc:", Index.key_prefix("doc", nil)
    # Multiple (or zero) definition prefixes can't be managed unambiguously.
    assert_nil Index.key_prefix(nil, IndexDefinition.new(prefix: %w[a: b:]))
    assert_nil Index.key_prefix(nil, nil)
  end

  def test_index_definition_emits_explicit_zero_score
    # In Ruby 0/0.0 are truthy, so an explicit zero score is emitted; only nil means "unset".
    assert_equal ["SCORE", 0], IndexDefinition.new(score: 0).args
    assert_equal ["SCORE", 0.0], IndexDefinition.new(score: 0.0).args
    assert_empty IndexDefinition.new(score: nil).args
  end

  # ---- Query building ----------------------------------------------------------------------

  def test_query_predicate_string
    query = Query.build do
      and_ do
        tag(:category).eq("greeting")
        text(:title).match("Hel*")
      end
    end

    query_string = query.to_redis_args.first
    assert_includes query_string, "@category:{greeting}"
    assert_includes query_string, "@title:Hel*"
  end

  def test_predicate_helpers_use_field_alias
    # A field created with `as:` must build predicates against the alias, not the raw name/path
    # (e.g. an aliased JSON path `$.brand AS brand` is queried as @brand, not @$.brand).
    query = Query.new
    Redis::Commands::Search::TagField.new("$.category", query, as: "category").eq("electronics")
    Redis::Commands::Search::TextField.new("$.brand", query, as: "brand").match("velorim")
    Redis::Commands::Search::NumericField.new("$.price", query, as: "price").between(10, 100)

    query_string = query.to_redis_args.first
    assert_includes query_string, "@category:{electronics}"
    assert_includes query_string, "@brand:velorim"
    assert_includes query_string, "@price:[10 100]"
    refute_includes query_string, "$."
  end

  def test_predicate_helpers_fall_back_to_name_without_alias
    query = Query.new
    Redis::Commands::Search::NumericField.new("price", query).gt(50)
    assert_includes query.to_redis_args.first, "@price:[(50 +inf]"
  end

  def test_ft_create_upcases_storage_type
    captured = nil
    client = Redis.new
    client.define_singleton_method(:send_command) { |command, &_block| captured = command }
    schema = Schema.build { text_field :title }

    client.ft_create("idx", schema, "hash", prefix: "x")
    on = captured.index("ON")
    assert_equal "HASH", captured[on + 1]

    captured = nil
    client.ft_create("idx", schema, :json)
    assert_equal "JSON", captured[captured.index("ON") + 1]
  end

  def test_ft_hybrid_search_omits_dialect
    # FT.HYBRID rejects a DIALECT token (server-enforced); it must never be appended.
    captured = nil
    client = Redis.new
    client.define_singleton_method(:send_command) { |command, &_block| captured = command }
    query = HybridQuery.new(
      HybridSearchQuery.new("@color:{red}"),
      HybridVsimQuery.new(vector_field_name: "@v", vector_data: "$vec")
    )

    client.ft_hybrid_search("idx", query: query, params_substitution: { "vec" => "blob" })
    refute_includes captured, "DIALECT"
  end

  def test_index_search_does_not_leak_options_across_calls
    captured = []
    client = Redis.new
    client.define_singleton_method(:send_command) do |command, &block|
      captured << command
      block ? block.call([0]) : [0]
    end
    index = Index.new(client, "idx", Schema.build { text_field :t }, "hash")
    query = Query.new("hello")

    index.search(query, params: { a: 1 }) # call 1: with PARAMS
    index.search(query) # call 2: same Query, no PARAMS

    assert_includes captured[0], "PARAMS"
    refute_includes captured[1], "PARAMS"
    refute query.options.key?(:params), "Index#search must not mutate the Query"
  end

  def test_index_search_empty_return_fields_falls_back_to_query
    captured = []
    client = Redis.new
    client.define_singleton_method(:send_command) do |command, &block|
      captured << command
      block ? block.call([0]) : [0]
    end
    index = Index.new(client, "idx", Schema.build { text_field :title }, "hash")
    query = Query.new("x").return("title")

    index.search(query, return_fields: [])         # empty -> use the Query's RETURN
    index.search(query, return_fields: ["price"])  # explicit -> override

    ret0 = captured[0].index("RETURN")
    refute_nil ret0, "empty return_fields must not omit the Query's RETURN clause"
    assert_equal "title", captured[0][ret0 + 2]
    ret1 = captured[1].index("RETURN")
    assert_equal "price", captured[1][ret1 + 2]
  end

  def test_index_search_explicit_false_overrides_query_flag
    captured = []
    client = Redis.new
    client.define_singleton_method(:send_command) do |command, &block|
      captured << command
      block ? block.call([0]) : [0]
    end
    index = Index.new(client, "idx", Schema.build { text_field :t }, "hash")
    query = Query.new("hello").no_content # the Query enables NOCONTENT

    index.search(query) # inherits NOCONTENT from the Query
    index.search(query, nocontent: false) # explicit false turns it off

    assert_includes captured[0], "NOCONTENT"
    refute_includes captured[1], "NOCONTENT"
  end

  def test_sort_by_without_asc_defaults_to_ascending_consistently
    # Raw ft_search and Index#search must emit the same SORTBY direction for the same call shape.
    captured = []
    client = Redis.new
    client.define_singleton_method(:send_command) do |command, &block|
      captured << command
      block ? block.call([0]) : [0]
    end

    client.ft_search("idx", "*", sort_by: "price") # raw convenience, no :asc
    index = Index.new(client, "idx", Schema.build { numeric_field :price }, "hash")
    index.search("*", sort_by: "price")            # Index#search, no :asc

    raw, idx = captured
    assert_equal "ASC", raw[raw.index("SORTBY") + 2]
    assert_equal "ASC", idx[idx.index("SORTBY") + 2]
  end

  def test_ft_search_sort_by_asc_false_is_descending
    captured = nil
    client = Redis.new
    client.define_singleton_method(:send_command) { |command, &_block| captured = command }

    client.ft_search("idx", "*", sort_by: "price", asc: false)
    assert_equal "DESC", captured[captured.index("SORTBY") + 2]
  end

  def test_ft_search_emits_timeout_infields_and_expander
    # ft_search must translate these options into FT.SEARCH tokens (previously dropped).
    captured = nil
    client = Redis.new
    client.define_singleton_method(:send_command) do |command, &block|
      captured = command
      block ? block.call([0]) : [0]
    end

    client.ft_search("idx", "hello", timeout: 500, expander: "SBSTEM", limit_fields: %w[title body])

    assert_equal 500, captured[captured.index("TIMEOUT") + 1]
    assert_equal "SBSTEM", captured[captured.index("EXPANDER") + 1]
    infields = captured.index("INFIELDS")
    assert_equal 2, captured[infields + 1]
    assert_equal %w[title body], captured[(infields + 2)..(infields + 3)]
  end

  def test_query_options_emitted
    query = Query.new("@category:{electronics}")
                 .paging(0, 10)
                 .sort_by(:price, :desc)
                 .with_scores
                 .no_content

    args = query.to_redis_args
    assert_includes args, "WITHSCORES"
    assert_includes args, "NOCONTENT"
    assert_includes args, "SORTBY"
    assert_includes args, "LIMIT"
  end

  def test_query_defaults_to_dialect_2
    assert_equal 2, Redis::Commands::Search::DEFAULT_DIALECT

    args = Query.new("hello").to_redis_args
    assert_equal 2, args[args.index("DIALECT") + 1]
  end

  def test_query_dialect_override
    args = Query.new("hello").dialect(3).to_redis_args
    assert_equal 3, args[args.index("DIALECT") + 1]
  end

  # ---- Aggregation building ----------------------------------------------------------------

  def test_aggregate_request_group_by_reduce
    req = AggregateRequest.new("redis").group_by("@parent", Reducers.count)
    args = req.to_redis_args
    assert_equal "redis", args.first
    assert_includes args, "GROUPBY"
    assert_includes args, "REDUCE"
    assert_includes args, "COUNT"
  end

  def test_aggregate_request_load_before_dialect
    req = AggregateRequest.new("*").load("t1").dialect(2)
    args = req.to_redis_args
    assert_operator args.index("LOAD"), :<, args.index("DIALECT")
  end

  def test_aggregate_request_defaults_to_dialect_2
    args = AggregateRequest.new("*").to_redis_args
    assert_equal 2, args[args.index("DIALECT") + 1]
  end

  def test_aggregate_request_apply_accepts_keyword_and_hash_forms
    # apply(expressions) takes a positional Hash; Ruby collects trailing key: value args into
    # it, so both the keyword form and an explicit hash render the same APPLY ... AS tokens.
    keyword = AggregateRequest.new("*").apply(times_ten: "@n * 10").to_redis_args
    hash = AggregateRequest.new("*").apply({ times_ten: "@n * 10" }).to_redis_args
    expected = ["APPLY", "@n * 10", "AS", "times_ten"]

    assert_equal expected, keyword.last(4)
    assert_equal expected, hash.last(4)
  end

  # ---- RESP2 reshaping ---------------------------------------------------------------------

  def test_search_resp2_basic
    result = RP.search([2, "doc1", ["title", "Hello"], "doc2", ["title", "Bye"]])
    assert_equal 2, result.total
    assert_equal 2, result.size
    assert_equal "doc1", result[0].id
    assert_equal "Hello", result[0]["title"]
  end

  def test_search_resp2_nocontent
    result = RP.search([2, "doc1", "doc2"], no_content: true)
    assert_equal 2, result.total
    assert_equal %w[doc1 doc2], result.map(&:id)
    assert_empty result[0].attributes
  end

  def test_search_resp2_with_scores
    # RESP2 returns the score as a bulk string; the parser normalizes it to a Float.
    result = RP.search([1, "doc1", "1.5", ["title", "Hi"]], with_scores: true)
    assert_in_delta 1.5, result[0].score
    assert_instance_of Float, result[0].score
    assert_equal "Hi", result[0]["title"]
  end

  def test_search_resp2_with_scores_and_nocontent
    result = RP.search([2, "doc1", "1.5", "doc2", "0.9"], with_scores: true, no_content: true)
    assert_equal "doc2", result[1].id
    assert_in_delta 0.9, result[1].score
    assert_instance_of Float, result[1].score
  end

  def test_search_score_explainscore_keeps_explanation_with_float_score
    # WITHSCORES + EXPLAINSCORE (RESP2): score slot is [score, explanation]; coerce the score
    # part to Float and keep the explanation intact.
    result = RP.search([1, "doc1", ["1.5", ["TFIDF", "0.5"]], ["title", "Hi"]], with_scores: true)
    assert_equal [1.5, ["TFIDF", "0.5"]], result[0].score
  end

  def test_search_decode_fields_parses_json
    result = RP.search([1, "d", ["meta", '{"a":1}']], decode_fields: { "meta" => true })
    assert_equal({ "a" => 1 }, result[0]["meta"])
  end

  def test_search_decode_fields_falls_back_on_non_json
    result = RP.search([1, "d", ["meta", "plain"]], decode_fields: { "meta" => true })
    assert_equal "plain", result[0]["meta"]
  end

  def test_search_decode_fields_with_symbol_keys_resp2
    # Symbol-keyed decode_fields (e.g. Query#return_field(:meta)) must still trigger decoding.
    result = RP.search([1, "d", ["meta", '{"a":1}']], decode_fields: { meta: true })
    assert_equal({ "a" => 1 }, result[0]["meta"])
  end

  def test_search_decode_fields_with_symbol_keys_resp3
    reply = { "total_results" => 1,
              "results" => [{ "id" => "d", "extra_attributes" => { "meta" => '{"a":1}' } }] }
    result = RP.search(reply, decode_fields: { meta: true })
    assert_equal({ "a" => 1 }, result[0]["meta"])
  end

  # ---- RESP3 reshaping ---------------------------------------------------------------------

  def test_search_resp3_map
    reply = {
      "total_results" => 1,
      "results" => [{ "id" => "doc1", "extra_attributes" => { "title" => "Hello" }, "score" => 2.0 }]
    }
    result = RP.search(reply)
    assert_equal 1, result.total
    assert_equal "doc1", result[0].id
    assert_equal "Hello", result[0]["title"]
    assert_in_delta 2.0, result[0].score
  end

  # ---- Aggregate reshaping -----------------------------------------------------------------

  def test_aggregate_resp2_rows
    result = RP.aggregate([2, %w[k a n 1], %w[k b n 2]])
    assert_equal 2, result.size
    assert_equal({ "k" => "a", "n" => "1" }, result[0])
    assert_nil result.cursor
  end

  def test_aggregate_with_cursor
    result = RP.aggregate([[1, %w[k a]], 42])
    assert_equal 42, result.cursor
    assert_equal({ "k" => "a" }, result[0])
  end

  # ---- Hybrid reshaping --------------------------------------------------------------------

  def test_hybrid_resp3_map
    reply = {
      "total_results" => 2,
      "results" => [{ "__key" => "item:1", "__score" => "0.5" }, { "__key" => "item:2", "__score" => "0.4" }],
      "warnings" => [],
      "execution_time" => 1.5
    }
    result = RP.hybrid(reply)
    assert_equal 2, result.total
    assert_equal 2, result.size
    assert_equal "item:1", result[0]["__key"]
    assert_in_delta 1.5, result.execution_time
    refute_predicate result, :cursor?
  end

  def test_hybrid_resp2_flat_array
    reply = ["total_results", 1, "results", [%w[__key item:1 __score 0.5 color red]], "warnings", []]
    result = RP.hybrid(reply)
    assert_equal 1, result.total
    assert_equal "item:1", result[0]["__key"]
    assert_equal "red", result[0]["color"]
  end

  def test_hybrid_cursor_reply
    # RESP2 WITHCURSOR reply carries per-leg cursor ids as a flat array.
    result = RP.hybrid(["SEARCH", 111, "VSIM", 222, "warnings", []])
    assert_predicate result, :cursor?
    assert_equal 111, result.search_cursor
    assert_equal 222, result.vsim_cursor
    assert_empty result.rows
  end

  # ---- Other reshapers ---------------------------------------------------------------------

  def test_hashify_info
    assert_equal({ "index_name" => "idx", "num_docs" => "5" },
                 RP.hashify_info(["index_name", "idx", "num_docs", "5"]))
  end

  def test_config_get_nested_pairs
    assert_equal({ "TIMEOUT" => "500" }, RP.config_get([["TIMEOUT", "500"]]))
  end

  def test_syndump
    assert_equal({ "guy" => %w[g1] }, RP.syndump(["guy", %w[g1]]))
  end

  def test_spellcheck_resp2
    parsed = RP.spellcheck([["TERM", "helo", [["0.5", "hello"]]]])
    assert_equal({ "helo" => [{ "suggestion" => "hello", "score" => "0.5" }] }, parsed)
  end

  def test_spellcheck_resp3
    parsed = RP.spellcheck({ "results" => { "hell" => [{ "hello" => 1.0 }] } })
    assert_equal({ "hell" => [{ "suggestion" => "hello", "score" => 1.0 }] }, parsed)
  end
end
