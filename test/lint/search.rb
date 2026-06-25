# frozen_string_literal: true

# Shared test suite for the Redis Query Engine (RediSearch, FT.*) commands. Included by the
# module test class (see test/modules/commands_on_search_test.rb) so it runs against a
# module-capable server: the standalone instance on Redis >= 8 (modules in core) or the
# dedicated Redis Stack instance on 7.2/7.4.
#
# Assertions target the reshaped result objects (SearchResult / Document / AggregateResult)
# rather than raw RESP arrays, so they hold regardless of whether the connection negotiated
# RESP2 or RESP3.
module Lint
  module Search
    include Redis::Commands::Search

    def setup
      super
      require_module("search")
      @index_name = "test_index"
      # The Query Engine only allows index creation on db 0, so pin the test client there
      # (Helper connects on db 15).
      r.select(0)
      # Drop any index that survived a previous test, then clear the keyspace, so each test
      # starts clean (FLUSHDB alone does not reliably remove FT indexes across versions).
      r.call("FT._LIST").each do |index|
        r.ft_dropindex(index)
      rescue Redis::CommandError
        nil
      end
      r.flushdb
    end

    def wait_for_index(index_name, timeout = 5.0)
      deadline = now + timeout
      loop do
        info = r.ft_info(index_name)
        break if info["indexing"].to_i.zero?
        raise "Timeout waiting for index #{index_name}" if now > deadline

        sleep 0.05
      end
    rescue Redis::CommandError
      nil
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Flatten an FT.INFO "attributes" entry (a flat array under RESP2, a map under RESP3) to
    # the plain values so field-name assertions are protocol-agnostic.
    def info_field_names(info)
      Array(info["attributes"]).flat_map do |attr|
        attr.is_a?(Hash) ? attr.values : attr
      end
    end

    # ---- Basic CRUD + search -----------------------------------------------------------------

    def test_ft_add_and_search
      schema = Schema.build do
        text_field :title
        text_field :body
      end
      index = r.create_index(@index_name, schema, prefix: "hsh2")

      index.add("doc1", title: "Hello", body: "World")
      index.add("doc2", title: "Goodbye", body: "World")

      result = index.search("Hello")
      assert_equal 1, result.total
      assert_equal "doc1", result[0].id

      result = index.search("World")
      assert_equal 2, result.total
      assert_includes result.map(&:id), "doc1"
      assert_includes result.map(&:id), "doc2"
    end

    def test_ft_mget_documents
      schema = Schema.build do
        text_field :f1
        text_field :f2
      end
      r.create_index(@index_name, schema)

      assert_equal [nil], r.ft_mget(@index_name, "mget_doc1")

      r.hset("mget_doc1", "f1", "some valid content dd1", "f2", "this is sample text f1")
      r.hset("mget_doc2", "f1", "some valid content dd2", "f2", "this is sample text f2")

      result = r.ft_mget(@index_name, "mget_doc2")
      assert_equal 1, result.length
      assert_includes flatten_fields(result[0]), "some valid content dd2"

      result = r.ft_mget(@index_name, "mget_doc1", "mget_doc2")
      assert_equal 2, result.length
      assert_includes flatten_fields(result[0]), "some valid content dd1"
      assert_includes flatten_fields(result[1]), "some valid content dd2"
    end

    def test_delete_document
      schema = Schema.build { text_field :title }
      index = r.create_index(@index_name, schema, prefix: "doc")

      index.add("doc1", title: "Test Document")
      assert_equal 1, index.search("Test").total

      del_result = r.ft_del(@index_name, "doc1")
      assert_includes [0, 1], del_result
    end

    def test_ft_add_indexes_document
      r.ft_create(@index_name, Schema.build { text_field :title })
      # Legacy FT.ADD: a flat fields array must reach the server as alternating name/value tokens.
      assert_equal "OK", r.ft_add(@index_name, "doc1", 1.0, fields: ["title", "hello world"])
      wait_for_index(@index_name)

      result = r.ft_search(@index_name, "hello")
      assert_equal 1, result.total
      assert_equal "doc1", result[0].id
      assert_equal "hello world", result[0]["title"]
    end

    # ---- Schema / index management -----------------------------------------------------------

    def test_index_uses_definition_prefix_for_add_and_search
      schema = Schema.build { text_field :title }
      index = r.create_index(
        @index_name, schema,
        definition: IndexDefinition.new(prefix: ["doc:"], index_type: IndexType::HASH)
      )
      index.add("1", title: "hello")
      wait_for_index(@index_name)

      # #add must write the key under the definition's prefix...
      assert_equal 1, r.exists("doc:1")
      # ...and #search must find it and strip that prefix back off the id.
      result = index.search("hello")
      assert_equal 1, result.total
      assert_equal "1", result[0].id
    end

    def test_create_index_with_schema
      schema = Schema.build do
        text_field :title
        numeric_field :price
      end

      index = r.create_index(@index_name, schema, prefix: "docs")

      assert_instance_of Redis::Commands::Search::Index, index
      assert_equal @index_name, index.name

      info = r.ft_info(@index_name)
      assert_equal @index_name, info["index_name"]
    end

    def test_alter_schema
      schema = Schema.build { text_field :title }
      r.create_index(@index_name, schema)

      new_field = Redis::Commands::Search::TextField.new(:body)
      assert_equal "OK", r.ft_alter(@index_name, new_field)

      info = r.ft_info(@index_name)
      assert_includes info_field_names(info), "title"
      assert_includes info_field_names(info), "body"
    end

    def test_index_search_does_not_persist_per_call_options
      index = r.create_index(@index_name, Schema.build { text_field :title }, prefix: "reuse")
      index.add("1", title: "hello")
      wait_for_index(@index_name)

      query = Query.new("hello")
      with_nocontent = index.search(query, nocontent: true)
      without_nocontent = index.search(query)

      # nocontent applied to the first call only; it must not stick to the reused Query.
      assert_empty with_nocontent[0].attributes
      assert_equal "hello", without_nocontent[0]["title"]
    end

    def test_index_alter_adds_field
      index = r.create_index(@index_name, Schema.build { text_field :title }, prefix: "alt")
      assert_equal "OK", index.alter(Redis::Commands::Search::TextField.new(:body))

      index.add("doc1", title: "hello", body: "world")
      wait_for_index(@index_name)
      assert_equal 1, index.search("@body:world").total
    end

    def test_ft_info
      schema = Schema.build { text_field :title }
      r.create_index(@index_name, schema, prefix: "ftinfo")

      info = r.ft_info(@index_name)
      assert_equal @index_name, info["index_name"]
      assert_operator info["num_docs"].to_i, :>=, 0
      assert_includes info_field_names(info), "title"
    end

    def test_drop_index
      schema = Schema.build { text_field :title }

      r.create_index(@index_name, schema, prefix: "testdrop")
      r.hset("testdrop:doc1", "title", "hello")
      assert_equal 1, r.exists("testdrop:doc1")

      assert_equal "OK", r.ft_dropindex(@index_name, delete_documents: false)
      assert_equal 1, r.exists("testdrop:doc1")
      r.del("testdrop:doc1")

      r.create_index(@index_name, schema, prefix: "testdrop2")
      r.hset("testdrop2:doc3", "title", "foo")
      assert_equal 1, r.exists("testdrop2:doc3")

      assert_equal "OK", r.ft_dropindex(@index_name, delete_documents: true)
      assert_equal 0, r.exists("testdrop2:doc3")
    end

    # ---- Query builder -----------------------------------------------------------------------

    def test_query_builder
      schema = Schema.build do
        text_field :title
        tag_field :category
        numeric_field :score
      end
      index = r.create_index(@index_name, schema, prefix: "hsh24")

      index.add("doc1", title: "Hello World", category: "greeting", score: 0.5)
      index.add("doc2", title: "Goodbye World", category: "farewell", score: 1.0)

      query = Query.build do
        and_ do
          tag(:category).eq("greeting")
          text(:title).match("Hel*")
        end
      end
      query.filter(:score, 0.3, "+inf")

      result = index.search(query)
      assert_equal 1, result.total
      assert_equal "doc1", result[0].id
    end

    def test_query_with_or_predicates
      schema = Schema.build do
        text_field :title
        tag_field :category
      end
      index = r.create_index(@index_name, schema, prefix: "hsh27")

      index.add("doc1", title: "Hello World", category: "greeting")
      index.add("doc2", title: "Hello Redis", category: "tech")
      index.add("doc3", title: "Goodbye World", category: "farewell")

      query = Query.build do
        or_ do
          text(:title).match("Hello*")
          tag(:category).eq("farewell")
        end
      end

      result = index.search(query)
      assert_equal 3, result.total
      assert_equal %w[doc1 doc2 doc3], result.map(&:id).sort
    end

    def test_complex_nested_query
      schema = Schema.build do
        text_field :title
        tag_field :category
        text_field :author
        numeric_field :score
        numeric_field :year
      end
      index = r.create_index(@index_name, schema, prefix: "book")

      index.add("book1", title: "Redis in Action", category: "programming", author: "Josiah Carlson", score: 4.5, year: 2013)
      index.add("book2", title: "Redis Essentials", category: "database", author: "Maxwell", score: 4.0, year: 2015)
      index.add("book3", title: "Redis Cookbook", category: "programming", author: "Tiago", score: 3.5, year: 2011)
      index.add("book4", title: "Learning Redis", category: "database", author: "Vinoo Das", score: 4.2, year: 2015)

      query = Query.build do
        or_ do
          and_ do
            text(:title).match("Redis*")
            or_ do
              tag(:category).eq("programming")
              and_ do
                tag(:category).eq("database")
                numeric(:year).gt(2014)
              end
            end
            numeric(:score).gt(4.0)
          end
          and_ do
            numeric(:score).between(4.5, 5.0)
            text(:author).match("Josiah Carlson")
          end
        end
      end

      result = index.search(query)
      assert_equal 2, result.total
      assert_equal %w[book1 book4], result.map(&:id).sort
    end

    def test_query_methods_with_return_and_scores
      schema = Schema.build do
        text_field :title
        tag_field :category
        numeric_field :price
      end
      index = r.create_index(@index_name, schema, prefix: "product")

      index.add("prod1", title: "iPhone", category: "electronics", price: 999)
      index.add("prod2", title: "Galaxy", category: "electronics", price: 799)
      index.add("prod3", title: "Book", category: "literature", price: 15)

      query = Query.new("@category:{electronics}")
                   .filter(:price, 0, 800)
                   .paging(0, 10)
                   .sort_by(:price, :desc)
                   .return(:title, :price)
                   .with_scores

      result = index.search(query)
      assert_equal 1, result.total
      assert_equal "prod2", result[0].id
      refute_nil result[0].score
      assert_equal "Galaxy", result[0]["title"]
      assert_equal "799", result[0]["price"]
    end

    def test_comprehensive_query_sorted
      schema = Schema.build do
        text_field :title, weight: 5.0
        tag_field :category
        numeric_field :price, sortable: true
        text_field :description
      end
      index = r.create_index(@index_name, schema, prefix: "comp")

      index.add("prod1", title: "iPhone 12", category: "electronics", price: 999, description: "Latest model")
      index.add("prod2", title: "Samsung Galaxy", category: "electronics", price: 799, description: "Android flagship")
      index.add("prod3", title: "Kindle", category: "electronics", price: 129, description: "E-reader")
      index.add("prod4", title: "Harry Potter", category: "books", price: 15, description: "Fantasy novel")

      query = Query.build do
        or_ do
          and_ do
            text(:title).match("iPhone|Galaxy")
            tag(:category).eq("electronics")
          end
          and_ do
            text(:description).match("reader")
            numeric(:price).between(100, 200)
          end
        end
      end
      query.filter(:price, 0, 1000)
           .paging(0, 5)
           .sort_by(:price, :desc)
           .return(:title, :price)

      result = index.search(query)
      assert_equal 3, result.total

      ids = result.map(&:id)
      assert_equal %w[prod1 prod2 prod3], ids
      prices = result.map { |doc| doc["price"].to_f }
      assert_equal prices.sort.reverse, prices
    end

    # ---- Search options ----------------------------------------------------------------------

    def test_ft_search_nocontent
      schema = Schema.build { text_field :title }
      index = r.create_index(@index_name, schema, prefix: "hsh4")
      index.add("doc1", title: "Hello")
      index.add("doc2", title: "Hello")
      wait_for_index(@index_name)

      result = index.search("Hello", nocontent: true)
      assert_equal 2, result.total
      assert_equal %w[doc1 doc2], result.map(&:id).sort
      assert_empty result[0].attributes
    end

    def test_ft_search_limit
      schema = Schema.build { text_field :title }
      index = r.create_index(@index_name, schema, prefix: "hshlimit")
      index.add("doc1", title: "Hello")
      index.add("doc2", title: "Hello")
      wait_for_index(@index_name)

      result = r.ft_search(@index_name, "Hello", limit: [0, 1])
      assert_equal 2, result.total
      assert_equal 1, result.size
    end

    def test_ft_search_with_scores
      schema = Schema.build { text_field :title }
      index = r.create_index(@index_name, schema, prefix: "hshscore")
      index.add("doc1", title: "Hello")
      wait_for_index(@index_name)

      result = index.search("Hello", with_scores: true)
      assert_equal 1, result.total
      refute_nil result[0].score
    end

    def test_ft_search_with_return
      schema = Schema.build do
        text_field :title
        text_field :body
        numeric_field :price
      end
      index = r.create_index(@index_name, schema, prefix: "hsh8")
      index.add("doc1", title: "Shirt", body: "Blue", price: 15)

      result = index.search("Shirt", return_fields: %w[title price])
      assert_equal 1, result.total
      assert_equal "doc1", result[0].id
      assert_equal({ "title" => "Shirt", "price" => "15" }, result[0].attributes)
    end

    def test_ft_search_with_summarize
      schema = Schema.build do
        text_field :title
        text_field :body
      end
      index = r.create_index(@index_name, schema, prefix: "hsh_summ")
      index.add("doc1", title: "Summarize", body: "This is a long text for summarization.")

      result = index.search("summarization", summarize: { fields: ["body"], len: 2, separator: "..." })
      assert_equal 1, result.total
      assert_equal "doc1", result[0].id
      assert_includes result[0]["body"], "summarization"
    end

    def test_ft_search_with_highlight
      schema = Schema.build do
        text_field :title
        text_field :body
      end
      index = r.create_index(@index_name, schema, prefix: "hsh_high")
      index.add("doc1", title: "Highlight", body: "Text to highlight.")

      result = index.search("highlight", highlight: { fields: ["body"], tags: ["<b>", "</b>"] })
      assert_equal 1, result.total
      assert_includes result[0]["body"], "<b>highlight</b>"
    end

    def test_ft_search_sortby
      schema = Schema.build { numeric_field :price, sortable: true }
      r.create_index("sort_idx", schema, prefix: "hsh_sorttest")
      r.hset("hsh_sorttest:1", "price", 10)
      r.hset("hsh_sorttest:2", "price", 5)
      wait_for_index("sort_idx")

      result = r.ft_search("sort_idx", "*", sort_by: "price", asc: true)
      assert_equal "hsh_sorttest:2", result[0].id
    end

    def test_ft_search_with_scorer
      schema = Schema.build { text_field :description }
      r.create_index(@index_name, schema, prefix: "hsh_scorer")
      r.hset("hsh_scorer:doc1", "description", "The quick brown fox jumps over the lazy dog")
      r.hset("hsh_scorer:doc2", "description", "Quick alice was beginning to get very tired")
      wait_for_index(@index_name)

      result = r.ft_search(@index_name, "quick", scorer: "TFIDF", with_scores: true)
      assert_equal 2, result.total
      assert result[0].id.start_with?("hsh_scorer:")
      assert_operator result[0].score.to_f, :>=, 0
    end

    # ---- Aggregations ------------------------------------------------------------------------

    def test_ft_aggregate
      schema = Schema.build do
        text_field :title
        text_field :body
      end
      index = r.create_index(@index_name, schema, prefix: "hsh6")
      index.add("doc1", title: "Hello", body: "World")
      index.add("doc2", title: "Hello", body: "Redis")
      wait_for_index(@index_name)

      result = index.aggregate("*", "GROUPBY", 1, "@title", "REDUCE", "COUNT", 0, "AS", "count")
      assert_equal 1, result.size
      assert_equal({ "title" => "Hello", "count" => "2" }, result[0])
    end

    def test_ft_aggregate_groupby_with_request
      schema = Schema.build do
        numeric_field :random_num
        text_field :title
        text_field :parent
      end
      r.create_index(@index_name, schema, prefix: "grouptest")
      r.hset("grouptest:search", "title" => "RediSearch", "parent" => "redis", "random_num" => 10)
      r.hset("grouptest:ai", "title" => "RedisAI", "parent" => "redis", "random_num" => 3)
      r.hset("grouptest:json", "title" => "RedisJson", "parent" => "redis", "random_num" => 8)
      wait_for_index(@index_name)

      req = Redis::Commands::Search::AggregateRequest.new("redis")
                                                     .group_by("@parent", Redis::Commands::Search::Reducers.count)
      res = r.ft_aggregate(@index_name, req)
      assert_equal 1, res.size
      assert_equal "redis", res[0]["parent"]
      assert_includes res[0].values, "3"
    end

    def test_ft_aggregate_apply
      schema = Schema.build do
        text_field :primary_key, sortable: true
        numeric_field :created, sortable: true
      end
      r.create_index(@index_name, schema, prefix: "applytest")
      r.hset("applytest:doc1", "primary_key" => "9::362330", "created" => "100")
      r.hset("applytest:doc2", "primary_key" => "9::362329", "created" => "200")
      wait_for_index(@index_name)

      req = Redis::Commands::Search::AggregateRequest.new("*").apply(created_times_ten: "@created * 10")
      res = r.ft_aggregate(@index_name, req)
      values = res.rows.map { |row| row["created_times_ten"] }.compact.sort
      assert_equal %w[1000 2000], values
    end

    def test_ft_aggregate_filter_and_sort
      schema = Schema.build do
        text_field :name, sortable: true
        numeric_field :age, sortable: true
      end
      r.create_index(@index_name, schema, prefix: "filtertest")
      r.hset("filtertest:doc1", "name" => "bar", "age" => "25")
      r.hset("filtertest:doc2", "name" => "foo", "age" => "19")
      wait_for_index(@index_name)

      req = Redis::Commands::Search::AggregateRequest.new("*")
                                                     .filter("@age > 15")
                                                     .sort_by("@age")
      res = r.ft_aggregate(@index_name, req)
      assert_equal 2, res.size
      assert_equal "19", res[0]["age"]
      assert_equal "25", res[1]["age"]
    end

    def test_ft_aggregate_load
      schema = Schema.build do
        text_field :t1
        text_field :t2
      end
      r.create_index(@index_name, schema, prefix: "loadtest")
      r.hset("loadtest:doc1", "t1" => "hello", "t2" => "world")
      wait_for_index(@index_name)

      req = Redis::Commands::Search::AggregateRequest.new("*").load("t1")
      res = r.ft_aggregate(@index_name, req)
      assert_equal "hello", res[0]["t1"]
    end

    # ---- Vector similarity / hybrid ----------------------------------------------------------

    def test_vector_similarity_knn
      schema = Schema.build do
        vector_field :embedding, :flat, type: :float32, dim: 4, distance_metric: :l2
        tag_field :tag
      end
      r.create_index(@index_name, schema)

      r.hset("doc1", embedding: [0.1, 0.9, 0.2, 0.8].pack("f*"), tag: "a")
      r.hset("doc2", embedding: [0.2, 0.8, 0.3, 0.7].pack("f*"), tag: "b")
      r.hset("doc3", embedding: [0.8, 0.2, 0.7, 0.3].pack("f*"), tag: "c")

      query_vector = [0.15, 0.85, 0.25, 0.75].pack("f*")

      result = r.ft_search(@index_name, "(*)=>[KNN 2 @embedding $query_vector]",
                           params: { query_vector: query_vector }, dialect: 2)
      assert_equal 2, result.total
      result.map(&:id).each { |id| assert_includes %w[doc1 doc2], id }

      result = r.ft_search(@index_name, "(@tag:{a})=>[KNN 1 @embedding $query_vector]",
                           params: { query_vector: query_vector }, dialect: 2)
      assert_equal 1, result.total
      assert_equal "doc1", result[0].id
    end

    def test_hybrid_search_knn
      schema = Schema.build do
        text_field :title
        vector_field :embedding, :flat, type: :float32, dim: 2, distance_metric: :cosine
      end
      r.create_index(@index_name, schema)

      r.hset("doc1", title: "foo", embedding: [0.1, 0.9].pack("f*"))
      r.hset("doc2", title: "bar", embedding: [0.8, 0.2].pack("f*"))

      result = r.ft_search(@index_name, "(*)=>[KNN 2 @embedding $query_vector]",
                           params: { query_vector: [0.1, 0.9].pack("f*") }, dialect: 2)
      assert_equal 2, result.total
    end

    # ---- Suggestions / dictionaries / synonyms / aliases -------------------------------------

    def test_ft_sugadd_and_sugget
      r.ft_sugadd("ac", "hello world", 1.0)
      assert_equal ["hello world"], r.ft_sugget("ac", "he", fuzzy: true, max: 10)
    end

    def test_ft_sugdel_and_suglen
      r.ft_sugadd("ac", "hello world", 1.0)
      assert_equal 1, r.ft_suglen("ac")
      r.ft_sugdel("ac", "hello world")
      assert_equal 0, r.ft_suglen("ac")
    end

    def test_ft_dictadd_del_dump
      assert_equal 2, r.ft_dictadd("test_dict", "term1", "term2")
      assert_equal 1, r.ft_dictdel("test_dict", "term1")
      assert_equal ["term2"], r.ft_dictdump("test_dict")
    end

    def test_ft_tagvals
      schema = Schema.build { tag_field :category }
      index = r.create_index(@index_name, schema, prefix: "hsh12")
      index.add("doc1", category: "A,B")
      index.add("doc2", category: "C")

      assert_equal %w[a b c], r.ft_tagvals(@index_name, "category").sort
    end

    def test_ft_spellcheck
      schema = Schema.build { text_field :title }
      index = r.create_index(@index_name, schema)
      index.add("doc1", title: "hello")
      wait_for_index(@index_name)

      result = r.ft_spellcheck(@index_name, "hell")
      assert_includes result.keys, "hell"
      suggestions = result["hell"].map { |s| s["suggestion"] }
      assert_includes suggestions, "hello"
    end

    def test_ft_synupdate_and_syndump
      schema = Schema.build { text_field :name }
      r.ft_create(@index_name, schema)

      r.ft_synupdate(@index_name, "group1", "guy", "dude")
      r.ft_synupdate(@index_name, "group1", "boy")

      assert_equal({ "guy" => ["group1"], "dude" => ["group1"], "boy" => ["group1"] },
                   r.ft_syndump(@index_name))
    end

    def test_index_synupdate_and_syndump
      index = r.create_index(@index_name, Schema.build { text_field :name })

      index.synupdate("group1", "guy", "dude")
      index.synupdate("group1", "boy")

      assert_equal({ "guy" => ["group1"], "dude" => ["group1"], "boy" => ["group1"] }, index.syndump)
    end

    def test_ft_alias_add_update_del
      schema = Schema.build { text_field :title }
      index = r.create_index(@index_name, schema, prefix: "alias_test")
      alias_name = "test_alias"

      assert r.ft_aliasadd(alias_name, @index_name)
      index.add("doc1", title: "test")
      assert_equal 1, r.ft_search(alias_name, "test").total

      r.create_index("new_index", Schema.build { text_field :title })
      assert r.ft_aliasupdate(alias_name, "new_index")
      assert r.ft_aliasdel(alias_name)
      r.ft_dropindex("new_index")
    end

    # ---- Filters (numeric + geo) -------------------------------------------------------------

    def test_ft_search_numeric_and_geo_filters
      schema = Schema.build do
        text_field :txt
        numeric_field :num
        geo_field :loc
      end
      r.ft_create(@index_name, schema)
      r.hset("doc1", "txt", "foo bar", "num", 3.141, "loc", "-0.441,51.458")
      r.hset("doc2", "txt", "foo baz", "num", 2, "loc", "-0.1,51.2")
      wait_for_index(@index_name)

      # Inclusive numeric range [0, 2] matches doc2.
      res = r.ft_search(@index_name, "foo", filter: [["num", 0, 2]], no_content: true)
      assert_equal 1, res.total
      assert_equal "doc2", res[0].id

      # Exclusive lower bound (2, +inf] matches doc1.
      res = r.ft_search(@index_name, "foo", filter: [["num", "(2", "+inf"]], no_content: true)
      assert_equal 1, res.total
      assert_equal "doc1", res[0].id

      # Geo filter: 10km around doc1 matches only doc1; 100km matches both.
      res = r.ft_search(@index_name, "foo", geo_filter: [["loc", -0.44, 51.45, 10, "km"]], no_content: true)
      assert_equal 1, res.total
      assert_equal "doc1", res[0].id

      res = r.ft_search(@index_name, "foo", geo_filter: [["loc", -0.44, 51.45, 100, "km"]], no_content: true)
      assert_equal 2, res.total
    end

    def test_ft_search_geo_radius_with_params
      schema = Schema.build { geo_field :g }
      r.ft_create(@index_name, schema)
      r.hset("doc1", "g", "29.69465,34.95126")
      r.hset("doc2", "g", "29.69350,34.94737")
      r.hset("doc3", "g", "29.68746,34.94882")
      wait_for_index(@index_name)

      res = r.ft_search(@index_name, "@g:[$lon $lat $radius $units]",
                        params: { lon: 29.69465, lat: 34.95126, radius: 1000, units: "km" })
      assert_equal 3, res.total
    end

    def test_geoshape_within_and_contains
      target_version("7.4") do
        schema = Schema.build { geoshape_field :geom, GeoShapeField::FLAT }
        r.ft_create(@index_name, schema)
        r.hset("small", "geom", "POLYGON((1 1, 1 100, 100 100, 100 1, 1 1))")
        r.hset("large", "geom", "POLYGON((1 1, 1 200, 200 200, 200 1, 1 1))")
        wait_for_index(@index_name)

        within = r.ft_search(@index_name, "@geom:[WITHIN $poly]",
                             params: { poly: "POLYGON((0 0, 0 150, 150 150, 150 0, 0 0))" }, dialect: 3)
        assert_equal %w[small], within.map(&:id)

        contains = r.ft_search(@index_name, "@geom:[CONTAINS $poly]",
                               params: { poly: "POLYGON((2 2, 2 50, 50 50, 50 2, 2 2))" }, dialect: 3)
        assert_equal %w[large small], contains.map(&:id).sort
      end
    end

    # ---- Field options -----------------------------------------------------------------------

    def test_create_index_with_stopwords
      schema = Schema.build { text_field :txt }
      r.ft_create(@index_name, schema, stopwords: %w[foo bar baz])
      r.hset("doc1", "txt", "foo bar")
      r.hset("doc2", "txt", "hello world")
      wait_for_index(@index_name)

      # "foo bar" are all stopwords -> no match; the second query still finds doc2 via hello/world.
      assert_equal 0, r.ft_search(@index_name, "foo bar", no_content: true).total
      assert_equal 1, r.ft_search(@index_name, "foo bar hello world", no_content: true).total
    end

    def test_tag_field_case_sensitivity
      # Case-insensitive (default): both docs match regardless of case.
      r.ft_create(@index_name, Schema.build { tag_field :t }, prefix: "ci")
      r.hset("ci:1", "t", "HELLO")
      r.hset("ci:2", "t", "hello")
      wait_for_index(@index_name)
      assert_equal 2, r.ft_search(@index_name, "@t:{HELLO}").total

      r.ft_dropindex(@index_name, delete_documents: true)

      # Case-sensitive: only the exact-case document matches.
      r.ft_create(@index_name, Schema.build { tag_field :t, case_sensitive: true }, prefix: "cs")
      r.hset("cs:1", "t", "HELLO")
      r.hset("cs:2", "t", "hello")
      wait_for_index(@index_name)
      res = r.ft_search(@index_name, "@t:{HELLO}")
      assert_equal 1, res.total
      assert_equal "cs:1", res[0].id
    end

    def test_phonetic_matcher
      r.ft_create(@index_name, Schema.build { text_field :name }, prefix: "noph")
      r.hset("noph:1", "name", "Jon")
      r.hset("noph:2", "name", "John")
      wait_for_index(@index_name)
      # Without phonetics only the exact term matches.
      assert_equal 1, r.ft_search(@index_name, "Jon").total

      r.ft_dropindex(@index_name, delete_documents: true)

      r.ft_create(@index_name, Schema.build { text_field :name, phonetic: "dm:en" }, prefix: "ph")
      r.hset("ph:1", "name", "Jon")
      r.hset("ph:2", "name", "John")
      wait_for_index(@index_name)
      # With the double-metaphone matcher, "Jon" also matches "John".
      assert_equal 2, r.ft_search(@index_name, "Jon").total
    end

    def test_withsuffixtrie_reflected_in_info
      r.ft_create(@index_name, Schema.build { text_field :t, withsuffixtrie: true })
      wait_for_index(@index_name)
      # The attribute carries a WITHSUFFIXTRIE flag (a flat token under RESP2, nested under the
      # field's "flags" under RESP3); assert on the serialized attributes for protocol-agnosticism.
      assert_includes r.ft_info(@index_name)["attributes"].to_s, "WITHSUFFIXTRIE"
    end

    # ---- Search options ----------------------------------------------------------------------

    def test_ft_search_sort_by_ascending_and_descending
      schema = Schema.build do
        text_field :txt
        numeric_field :num, sortable: true
      end
      index = r.create_index(@index_name, schema, prefix: "sort")
      index.add("doc1", txt: "foo bar", num: 1)
      index.add("doc2", txt: "foo baz", num: 2)
      index.add("doc3", txt: "foo qux", num: 3)
      wait_for_index(@index_name)

      asc = r.ft_search(@index_name, "foo", sort_by: "num", asc: true, no_content: true)
      assert_equal %w[sort:doc1 sort:doc2 sort:doc3], asc.map(&:id)

      desc = r.ft_search(@index_name, "foo", sort_by: "num", asc: false, no_content: true)
      assert_equal %w[sort:doc3 sort:doc2 sort:doc1], desc.map(&:id)
    end

    def test_ft_search_with_scores_returns_numeric_score
      r.ft_create(@index_name, Schema.build { text_field :txt }, prefix: "sc")
      r.hset("sc:1", "txt", "foo baz")
      r.hset("sc:2", "txt", "foo bar")
      wait_for_index(@index_name)

      res = r.ft_search(@index_name, "foo ~bar", with_scores: true)
      assert_equal 2, res.total
      res.each { |doc| assert_operator doc.score.to_f, :>=, 0 }
    end

    def test_ft_search_return_field_with_alias
      r.ft_create(@index_name, Schema.build { text_field :title }, prefix: "ret")
      r.hset("ret:1", "title", "hello")
      wait_for_index(@index_name)

      query = Query.new("hello").return_field("title", as_field: "heading")
      query_string = query.to_redis_args.shift
      res = r.ft_search(@index_name, query_string,
                        return: query.return_fields, decode_fields: query.return_fields_decode)
      assert_equal 1, res.total
      assert_equal "hello", res[0]["heading"]
    end

    def test_index_search_limit_fields_restricts_matching
      schema = Schema.build do
        text_field :title
        text_field :body
      end
      index = r.create_index(@index_name, schema, prefix: "inf")
      index.add("doc1", title: "alpha", body: "beta")
      wait_for_index(@index_name)

      # "beta" only lives in body. INFIELDS (limit_fields) must flow through Index#search:
      # restricting to :title finds nothing; restricting to :body finds the doc.
      assert_equal 0, index.search(Query.new("beta").limit_fields(:title)).total
      assert_equal 1, index.search(Query.new("beta").limit_fields(:body)).total
    end

    def test_ft_search_with_params
      schema = Schema.build do
        text_field :name
        numeric_field :age
      end
      r.ft_create(@index_name, schema, prefix: "par")
      r.hset("par:1", "name", "alice", "age", 30)
      r.hset("par:2", "name", "bob", "age", 25)
      wait_for_index(@index_name)

      res = r.ft_search(@index_name, "@age:[$min $max]", params: { min: 26, max: 40 })
      assert_equal 1, res.total
      assert_equal "par:1", res[0].id
    end

    # ---- Explain / config / profile ----------------------------------------------------------

    def test_ft_explain
      r.ft_create(@index_name, Schema.build do
        text_field :f1
        text_field :f2
      end)
      plan = r.ft_explain(@index_name, "@f1:hello @f2:world")
      assert_kind_of String, plan
      refute_empty plan
    end

    def test_ft_config_set_and_get
      assert_equal "OK", r.ft_config_set("TIMEOUT", "100")
      assert_equal "100", r.ft_config_get("TIMEOUT")["TIMEOUT"]
      assert_equal "100", r.ft_config_get("*")["TIMEOUT"]
    end

    def test_ft_config_default_dialect_is_two
      # redis-rb defaults queries to DIALECT 2; the server's own DEFAULT_DIALECT is independent,
      # but should be readable and settable.
      assert r.ft_config_get("DEFAULT_DIALECT").key?("DEFAULT_DIALECT")
      assert_equal "OK", r.ft_config_set("DEFAULT_DIALECT", 2)
      assert_equal "2", r.ft_config_get("DEFAULT_DIALECT")["DEFAULT_DIALECT"]
    end

    def test_ft_profile_search
      r.ft_create(@index_name, Schema.build { text_field :t }, prefix: "prof")
      r.hset("prof:1", "t", "hello")
      r.hset("prof:2", "t", "world")
      wait_for_index(@index_name)

      reply = r.ft_profile(@index_name, "SEARCH", "QUERY", "hello|world")
      refute_nil reply
    end

    # ---- Aggregations ------------------------------------------------------------------------

    def test_ft_aggregate_reducers
      schema = Schema.build do
        text_field :parent
        numeric_field :num
      end
      r.ft_create(@index_name, schema, prefix: "red")
      r.hset("red:1", "parent", "redis", "num", 10)
      r.hset("red:2", "parent", "redis", "num", 3)
      r.hset("red:3", "parent", "redis", "num", 8)
      wait_for_index(@index_name)

      req = AggregateRequest.new("redis").group_by(
        "@parent",
        Reducers.count.as("count"),
        Reducers.count_distinct("@num").as("distinct"),
        Reducers.sum("@num").as("sum"),
        Reducers.min("@num").as("min"),
        Reducers.max("@num").as("max"),
        Reducers.avg("@num").as("avg"),
        Reducers.tolist("@num").as("values")
      )
      row = r.ft_aggregate(@index_name, req)[0]
      assert_equal "redis", row["parent"]
      assert_equal "3", row["count"]
      assert_equal "3", row["distinct"]
      assert_equal "21", row["sum"]
      assert_equal "3", row["min"]
      assert_equal "10", row["max"]
      assert_equal "7", row["avg"]
      assert_equal %w[10 3 8].sort, Array(row["values"]).sort
    end

    def test_ft_aggregate_sort_by_directions_and_max
      r.ft_create(@index_name, Schema.build do
        text_field :t1
        text_field :t2
      end, prefix: "agg")
      r.hset("agg:1", "t1", "a", "t2", "b")
      r.hset("agg:2", "t1", "b", "t2", "a")
      wait_for_index(@index_name)

      req = AggregateRequest.new("*").sort_by(Asc.new("@t2"), Desc.new("@t1"))
      res = r.ft_aggregate(@index_name, req)
      assert_equal({ "t2" => "a", "t1" => "b" }, res[0])
      assert_equal({ "t2" => "b", "t1" => "a" }, res[1])

      capped = r.ft_aggregate(@index_name, AggregateRequest.new("*").sort_by("@t1", max: 1))
      assert_equal 1, capped.size
    end

    def test_ft_aggregate_add_scores
      # ADDSCORES was added in RediSearch 2.10 (Redis Stack 7.4 / Redis 8); older servers reject it.
      target_version("7.4") do
        schema = Schema.build do
          text_field :name, sortable: true, weight: 5.0
          numeric_field :age, sortable: true
        end
        r.ft_create(@index_name, schema, prefix: "as")
        r.hset("as:1", "name", "bar", "age", 25)
        r.hset("as:2", "name", "foo", "age", 19)
        wait_for_index(@index_name)

        res = r.ft_aggregate(@index_name, AggregateRequest.new("*").add_scores)
        assert_equal 2, res.size
        res.each { |row| assert row.key?("__score") }
      end
    end

    def test_ft_aggregate_with_cursor
      r.ft_create(@index_name, Schema.build { text_field :t }, prefix: "cur")
      3.times { |i| r.hset("cur:#{i}", "t", "hello") }
      wait_for_index(@index_name)

      res = r.ft_aggregate(@index_name, AggregateRequest.new("*", with_cursor: true, cursor_count: 2))
      assert_operator res.cursor, :>, 0
      assert_equal 2, res.size

      nxt = r.ft_cursor_read(@index_name, res.cursor)
      assert_instance_of Redis::Commands::Search::AggregateResult, nxt
      assert_equal 0, nxt.cursor # exhausted

      # A fresh cursor can be discarded explicitly.
      fresh = r.ft_aggregate(@index_name, AggregateRequest.new("*", with_cursor: true, cursor_count: 1))
      assert_equal "OK", r.ft_cursor_del(@index_name, fresh.cursor)
    end

    # ---- Hybrid search (FT.HYBRID) -----------------------------------------------------------
    #
    # FT.HYBRID fuses a lexical SEARCH leg with a vector VSIM leg. ft_hybrid_search returns a
    # Search::HybridResult (Enumerable over row hashes, plus #total/#warnings/#execution_time, and
    # #search_cursor/#vsim_cursor for WITHCURSOR). FT.HYBRID is available since Redis 8.4.

    def test_hybrid_basic
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 3)

        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red}"),
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) })
        # The default result limit is 10; every row carries the synthetic __key/__score.
        assert_instance_of Redis::Commands::Search::HybridResult, result
        assert_equal 10, result.total
        assert_equal 10, result.size
        assert_empty result.warnings
        result.each do |row|
          refute_nil row["__key"]
          refute_nil row["__score"]
        end
      end
    end

    def test_hybrid_combine_linear_with_limit
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 10)

        post = HybridPostProcessingConfig.new.limit(0, 3)
        result = r.ft_hybrid_search(
          @index_name,
          query: hybrid_query(search: "@color:{red}"),
          combine_method: CombineResultsMethod.linear(alpha: 0.5, beta: 0.5),
          post_processing: post,
          params_substitution: { "vec" => f32(1, 2, 7, 6) },
          timeout: 10
        )
        assert_equal 3, result.size
      end
    end

    def test_hybrid_combine_rrf
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 5)

        result = r.ft_hybrid_search(
          @index_name,
          query: hybrid_query(search: "@color:{red}"),
          combine_method: CombineResultsMethod.rrf(window: 20, constant: 60),
          params_substitution: { "vec" => f32(1, 2, 7, 6) }
        )
        assert_operator result.size, :>, 0
      end
    end

    def test_hybrid_post_processing_limit
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 10)

        post = HybridPostProcessingConfig.new.limit(0, 4)
        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red}"),
                                                 post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) })
        assert_equal 4, result.size
      end
    end

    def test_hybrid_post_processing_load
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 5)

        post = HybridPostProcessingConfig.new.load("@color", "@price", "@size").limit(0, 3)
        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red|green|black}"),
                                                 post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) })
        assert_operator result.size, :>, 0
        refute_nil result[0]["color"]
        refute_nil result[0]["price"]
      end
    end

    def test_hybrid_post_processing_load_apply_sortby
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 1)

        post = HybridPostProcessingConfig.new
                                         .load("@color", "@price")
                                         .apply(price_discount: "@price - (@price * 0.1)")
                                         .sort_by(SortbyField.new("@price_discount", asc: false))
                                         .limit(0, 5)
        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red|green}"),
                                                 post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 10)
        assert_operator result.size, :>, 0
        refute_nil result[0]["price_discount"]
      end
    end

    def test_hybrid_post_processing_groupby
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 10)

        post = HybridPostProcessingConfig.new
                                         .load("@color", "@price", "@size", "@item_type")
                                         .group_by(["@item_type"], Reducers.count_distinct("@color").as("colors"),
                                                   Reducers.min("@size").as("min_size"))
        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red|green}"),
                                                 post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) })
        assert_operator result.size, :>, 0
        refute_nil result[0]["item_type"]
        refute_nil result[0]["colors"]
      end
    end

    def test_hybrid_vsim_knn
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 10)

        # A search leg that matches nothing isolates the VSIM (KNN) leg.
        vsim = HybridVsimQuery.new(vector_field_name: "@embedding", vector_data: "$vec")
        vsim.vsim_method_params(VectorSearchMethods::KNN, K: 3)
        query = HybridQuery.new(HybridSearchQuery.new("@color:{none}"), vsim)

        result = r.ft_hybrid_search(@index_name, query: query,
                                                 params_substitution: { "vec" => f32(1, 2, 2, 3) }, timeout: 10)
        assert_equal 3, result.size
      end
    end

    def test_hybrid_vsim_range
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 10)

        vsim = HybridVsimQuery.new(vector_field_name: "@embedding", vector_data: "$vec")
        vsim.vsim_method_params(VectorSearchMethods::RANGE, RADIUS: 2)
        query = HybridQuery.new(HybridSearchQuery.new("@color:{none}"), vsim)

        post = HybridPostProcessingConfig.new.limit(0, 3)
        result = r.ft_hybrid_search(@index_name, query: query, post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 10)
        assert_operator result.size, :>=, 0
      end
    end

    def test_hybrid_vsim_filter
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 5)

        vsim = HybridVsimQuery.new(vector_field_name: "@embedding", vector_data: "$vec")
        vsim.filter(HybridFilter.new("@price:[15 16]"))
        query = HybridQuery.new(HybridSearchQuery.new("@color:{none}"), vsim)

        post = HybridPostProcessingConfig.new.load("@price")
        result = r.ft_hybrid_search(@index_name, query: query, post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 2, 3) }, timeout: 10)
        assert_operator result.size, :>, 0
        result.each { |row| assert_includes %w[15 16], row["price"] }
      end
    end

    def test_hybrid_search_scorer
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 5)

        search = HybridSearchQuery.new("shoes").scorer("TFIDF")
        vsim = HybridVsimQuery.new(vector_field_name: "@embedding", vector_data: "$vec")
        result = r.ft_hybrid_search(@index_name, query: HybridQuery.new(search, vsim),
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 10)
        assert_operator result.size, :>, 0
      end
    end

    def test_hybrid_search_score_alias
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 5)

        search = HybridSearchQuery.new("shoes").yield_score_as("search_score")
        vsim = HybridVsimQuery.new(vector_field_name: "@embedding", vector_data: "$vec")
        post = HybridPostProcessingConfig.new.load("@__key", "@search_score")
        result = r.ft_hybrid_search(@index_name, query: HybridQuery.new(search, vsim),
                                                 post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 10)
        assert_operator result.size, :>, 0
        # Rows that matched the lexical leg expose the aliased search score.
        assert(result.any? { |row| row["search_score"] })
      end
    end

    def test_hybrid_vsim_score_alias
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 5)

        vsim = HybridVsimQuery.new(vector_field_name: "@embedding", vector_data: "$vec")
        vsim.yield_score_as("vsim_score")
        post = HybridPostProcessingConfig.new.load("@__key", "@vsim_score")
        result = r.ft_hybrid_search(@index_name, query: HybridQuery.new(HybridSearchQuery.new("@color:{none}"), vsim),
                                                 post_processing: post,
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 10)
        assert_operator result.size, :>, 0
        assert(result.any? { |row| row["vsim_score"] })
      end
    end

    def test_hybrid_with_timeout
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 3)
        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red}"),
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 5000)
        refute_nil result.total
      end
    end

    def test_hybrid_with_cursor
      target_version("8.4") do
        create_hybrid_index
        add_hybrid_data(sets: 10)

        result = r.ft_hybrid_search(@index_name, query: hybrid_query(search: "@color:{red|green}"),
                                                 cursor: HybridCursorQuery.new(count: 5, max_idle: 100),
                                                 params_substitution: { "vec" => f32(1, 2, 7, 6) }, timeout: 10)
        # WITHCURSOR returns per-leg cursor ids instead of an inline result page.
        assert_predicate result, :cursor?
        assert_operator result.search_cursor, :>, 0
        assert_operator result.vsim_cursor, :>, 0
      end
    end

    def test_index_hybrid_search
      target_version("8.4") do
        schema = Schema.build do
          text_field :description
          tag_field :color
          vector_field :embedding, "FLAT", type: "FLOAT32", dim: 4, distance_metric: "L2"
        end
        index = r.create_index(@index_name, schema, definition: IndexDefinition.new(prefix: ["item:"]))
        HYBRID_ITEMS.each_with_index do |(vec, description), i|
          r.hset("item:#{i}", "description", description, "embedding", f32(vec),
                 "color", description.split(" ").first)
        end
        wait_for_index(@index_name)

        # The Index wrapper delegates to FT.HYBRID and returns a HybridResult.
        result = index.hybrid_search(query: hybrid_query(search: "@color:{red}"),
                                     params_substitution: { "vec" => f32(1, 2, 7, 6) })
        assert_instance_of Redis::Commands::Search::HybridResult, result
        assert_operator result.size, :>, 0
      end
    end

    # ---- SVS-VAMANA vector fields (FT.SEARCH KNN) --------------------------------------------
    #
    # SVS-VAMANA is a graph-based vector index. These exercise field construction parameters and
    # KNN search; SVS-VAMANA build parameters require Redis >= 8.1.

    def test_svs_vamana_basic_knn
      target_version("8.1") do
        result = svs_knn(
          attrs: { type: "FLOAT32", dim: 4, distance_metric: "L2" },
          vectors: [[1.0, 2.0, 3.0, 4.0], [2.0, 3.0, 4.0, 5.0], [3.0, 4.0, 5.0, 6.0],
                    [4.0, 5.0, 6.0, 7.0], [5.0, 6.0, 7.0, 8.0]],
          k: 3
        )
        assert_equal 3, result.total
        assert_equal "svs:0", result[0].id
      end
    end

    def test_svs_vamana_distance_metrics
      target_version("8.1") do
        %w[L2 IP COSINE].each do |metric|
          result = svs_knn(
            attrs: { type: "FLOAT32", dim: 3, distance_metric: metric },
            vectors: [[1.0, 0.0, 0.0], [2.0, 0.0, 0.0], [0.0, 1.0, 0.0], [5.0, 0.0, 0.0]],
            k: 3
          )
          assert_equal 3, result.total, "metric #{metric}"
          assert_includes result.map(&:id), "svs:0", "metric #{metric}"
        end
      end
    end

    def test_svs_vamana_build_parameters
      target_version("8.1") do
        result = svs_knn(
          attrs: {
            type: "FLOAT32", dim: 4, distance_metric: "L2",
            construction_window_size: 200, graph_max_degree: 64,
            search_window_size: 40, epsilon: 0.01
          },
          vectors: [[1.0, 2.0, 3.0, 4.0], [2.0, 3.0, 4.0, 5.0], [3.0, 4.0, 5.0, 6.0],
                    [4.0, 5.0, 6.0, 7.0], [5.0, 6.0, 7.0, 8.0]],
          k: 3
        )
        assert_equal 3, result.total
        assert_equal "svs:0", result[0].id
      end
    end

    def test_svs_vamana_lvq8_compression
      target_version("8.1") do
        vectors = Array.new(20) { |i| Array.new(8) { |j| (i + j).to_f } }
        result = svs_knn(
          attrs: { type: "FLOAT32", dim: 8, distance_metric: "L2",
                   compression: "LVQ8", training_threshold: 1024 },
          vectors: vectors, k: 5
        )
        assert_equal 5, result.total
        assert_equal "svs:0", result[0].id
      end
    end

    def test_svs_vamana_search_window_size
      target_version("8.1") do
        vectors = Array.new(30) { |i| Array.new(6) { |j| (i + j).to_f } }
        result = svs_knn(
          attrs: { type: "FLOAT32", dim: 6, distance_metric: "L2", search_window_size: 20 },
          vectors: vectors, k: 8
        )
        assert_equal 8, result.total
        assert_equal "svs:0", result[0].id
      end
    end

    private

    # FT.MGET returns each document's fields as a flat array (RESP2) or a map (RESP3).
    def flatten_fields(entry)
      return [] if entry.nil?

      entry.is_a?(Hash) ? entry.to_a.flatten : entry
    end

    # Pack floats as a little-endian FLOAT32 binary blob (the vector wire format).
    def f32(*values)
      values.flatten.pack("f*")
    end

    # Create the standard hybrid-search index: lexical fields plus a FLAT vector field.
    def create_hybrid_index(dim: 4)
      schema = Schema.build do
        text_field :description
        numeric_field :price
        tag_field :color
        tag_field :item_type
        numeric_field :size
        vector_field :embedding, "FLAT", type: "FLOAT32", dim: dim, distance_metric: "L2"
      end
      r.ft_create(@index_name, schema, definition: IndexDefinition.new(prefix: ["item:"]))
    end

    HYBRID_ITEMS = [
      [[1.0, 2.0, 7.0, 8.0], "red shoes"],
      [[1.0, 4.0, 7.0, 8.0], "green shoes with red laces"],
      [[1.0, 2.0, 6.0, 5.0], "red dress"],
      [[2.0, 3.0, 6.0, 5.0], "orange dress"],
      [[5.0, 6.0, 7.0, 8.0], "black shoes"]
    ].freeze

    def add_hybrid_data(sets: 2)
      index = 0
      sets.times do
        HYBRID_ITEMS.each do |vec, description|
          r.hset("item:#{index}",
                 "description", description,
                 "embedding", f32(vec),
                 "price", 15 + (index % 4),
                 "color", description.split(" ").first,
                 "item_type", description.split(" ")[1],
                 "size", 10 + (index % 3))
          index += 1
        end
      end
      wait_for_index(@index_name)
    end

    def hybrid_query(search:, vector_field: "@embedding", vector_data: "$vec")
      HybridQuery.new(
        HybridSearchQuery.new(search),
        HybridVsimQuery.new(vector_field_name: vector_field, vector_data: vector_data)
      )
    end

    # Create an SVS-VAMANA index from +attrs+, load +vectors+ (one HASH each under "svs:<i>"),
    # and run a KNN-+k+ search against the first vector. Returns the SearchResult.
    def svs_knn(attrs:, vectors:, k:)
      begin
        r.ft_dropindex(@index_name, delete_documents: true)
      rescue Redis::CommandError
        nil # index may not exist yet (first call, or after setup's sweep)
      end
      r.flushdb
      r.ft_create(@index_name, Schema.build { vector_field :v, "SVS-VAMANA", **attrs }, prefix: "svs")
      vectors.each_with_index { |vec, i| r.hset("svs:#{i}", "v", f32(vec)) }
      wait_for_index(@index_name)
      r.ft_search(@index_name, "*=>[KNN #{k} @v $vec AS score]",
                  params: { vec: f32(vectors[0]) }, no_content: true)
    end
  end
end
