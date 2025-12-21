# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchAggregation < Minitest::Test
  include Helper::Client
  include Redis::Commands::Search

  def setup
    super
    @index_name = "test_index"
    r.select(0)

    # Check if Search module is available
    begin
      r.call('FT._LIST')
    rescue Redis::CommandError
      skip "Search module not available"
    end

    begin
      r.ft_dropindex(@index_name, delete_documents: true)
    rescue
      nil
    end
  end

  def wait_for_index(index_name, timeout: 5.0)
    delay = 0.1
    elapsed = 0
    while elapsed < timeout
      begin
        info = r.ft_info(index_name)
        if info['indexing'].to_i == 0
          return true
        end
      rescue Redis::CommandError
        # Index doesn't exist yet, continue waiting
      end
      sleep(delay)
      elapsed += delay
    end
    false
  end

  def test_ft_aggregate
    schema = Schema.build do
      text_field :title
      text_field :body
    end
    index = r.create_index(@index_name, schema, prefix: "hsh6")

    index.add('doc1', title: 'Hello', body: 'World')
    index.add('doc2', title: 'Hello', body: 'Redis')
    wait_for_index(@index_name)

    result = index.aggregate('*', 'GROUPBY', 1, '@title', 'REDUCE', 'COUNT', 0, 'AS', 'count')
    assert_equal 1, result[0]
    assert_equal ['title', 'Hello', 'count', '2'], result[1]
  end

  def test_ft_aggregate_complex
    schema = Schema.build do
      text_field :title
      tag_field :category
    end
    index = r.create_index(@index_name, schema, prefix: "hsh10")

    index.add('doc1', title: 'Hello', category: 'A')
    index.add('doc2', title: 'World', category: 'B')
    index.add('doc3', title: 'Redis', category: 'A')
    wait_for_index(@index_name)

    result = index.aggregate('*', 'GROUPBY', 1, '@category', 'REDUCE', 'COUNT', 0, 'AS', 'count', 'SORTBY', 2, '@count', 'DESC')
    assert_equal [2, ["category", "A", "count", "2"], ["category", "B", "count", "1"]], result
  end

  def test_aggregations_groupby
    # Create index
    schema = Schema.build do
      numeric_field :random_num
      text_field :title
      text_field :body
      text_field :parent
    end
    r.create_index(@index_name, schema, prefix: "grouptest")

    # Index documents
    r.hset("grouptest:search", {
             "title" => "RediSearch",
             "body" => "Redisearch implements a search engine on top of redis",
             "parent" => "redis",
             "random_num" => 10
           })
    r.hset("grouptest:ai", {
             "title" => "RedisAI",
             "body" => "RedisAI executes Deep Learning/Machine Learning models and managing their data.",
             "parent" => "redis",
             "random_num" => 3
           })
    r.hset("grouptest:json", {
             "title" => "RedisJson",
             "body" => "RedisJSON implements ECMA-404 The JSON Data Interchange Standard as a native data type.",
             "parent" => "redis",
             "random_num" => 8
           })
    wait_for_index(@index_name)

    # Test count reducer
    req = Redis::Commands::Search::AggregateRequest.new("redis")
                                                   .group_by("@parent", Redis::Commands::Search::Reducers.count)

    res = r.ft_aggregate(@index_name, req)
    assert_equal 1, res[0] # Total results
    assert_includes res[1], "parent"
    assert_includes res[1], "redis"
    assert_includes res[1], "__generated_aliascount"
    assert_includes res[1], "3"

    # Test count_distinct reducer
    req = Redis::Commands::Search::AggregateRequest.new("redis")
                                                   .group_by("@parent", Redis::Commands::Search::Reducers.count_distinct("@title"))

    res = r.ft_aggregate(@index_name, req)
    assert_equal 1, res[0]
    assert_includes res[1], "3"

    # Test count_distinctish reducer
    req = Redis::Commands::Search::AggregateRequest.new("redis")
                                                   .group_by("@parent", Redis::Commands::Search::Reducers.count_distinctish("@title"))

    res = r.ft_aggregate(@index_name, req)
    assert_equal 1, res[0]
    assert_includes res[1], "3"
  end

  def test_aggregations_apply
    schema = Schema.build do
      text_field :PrimaryKey, sortable: true
      numeric_field :CreatedDateTimeUTC, sortable: true
    end
    r.create_index(@index_name, schema, prefix: "applytest")

    r.hset("applytest:doc1", {
             "PrimaryKey" => "9::362330",
             "CreatedDateTimeUTC" => "637387878524969984"
           })
    r.hset("applytest:doc2", {
             "PrimaryKey" => "9::362329",
             "CreatedDateTimeUTC" => "637387875859270016"
           })

    wait_for_index(@index_name)

    req = Redis::Commands::Search::AggregateRequest.new("*")
                                                   .apply(CreatedDateTimeUTC: "@CreatedDateTimeUTC * 10")

    res = r.ft_aggregate(@index_name, req)
    # First element is total count, then alternating result arrays
    # Result format: [count, [field, value], [field, value], ...]
    assert_equal 1, res[0]

    # Extract the CreatedDateTimeUTC values from results
    # Results are at indices 1 and 2 (each is an array)
    res_set = [res[1], res[2]].map do |row|
      idx = row.index("CreatedDateTimeUTC")
      row[idx + 1] if idx
    end.compact.to_set

    assert_equal Set["6373878785249699840", "6373878758592700416"], res_set
  end

  def test_aggregations_filter
    schema = Schema.build do
      text_field :name, sortable: true
      numeric_field :age, sortable: true
    end
    r.create_index(@index_name, schema, prefix: "filtertest")

    r.hset("filtertest:doc1", { "name" => "bar", "age" => "25" })
    r.hset("filtertest:doc2", { "name" => "foo", "age" => "19" })
    wait_for_index(@index_name)

    [1, 2].each do |dialect|
      req = Redis::Commands::Search::AggregateRequest.new("*")
                                                     .filter("@name=='foo' && @age < 20")
                                                     .dialect(dialect)

      res = r.ft_aggregate(@index_name, req)
      # Result format: [total_count, [field, value, field, value, ...]]
      # The total_count is the number of documents in the index, not filtered count
      # We have 1 result row (res[1])
      assert_equal 1, res.size - 1 # Number of result rows (excluding count)
      assert_equal ["name", "foo", "age", "19"], res[1]

      # Test with sort_by
      req = Redis::Commands::Search::AggregateRequest.new("*")
                                                     .filter("@age > 15")
                                                     .sort_by("@age")
                                                     .dialect(dialect)

      res = r.ft_aggregate(@index_name, req)
      assert_equal 2, res.size - 1 # 2 result rows
      assert_equal ["age", "19"], res[1]
      assert_equal ["age", "25"], res[2]
    end
  end

  def test_aggregations_sort_by_and_limit
    schema = Schema.build do
      text_field :t1
      text_field :t2
    end
    r.create_index(@index_name, schema)

    r.hset("doc1", { "t1" => "a", "t2" => "b" })
    r.hset("doc2", { "t1" => "b", "t2" => "a" })

    # Test sort_by using SortDirection
    req = Redis::Commands::Search::AggregateRequest.new("*")
                                                   .sort_by(Redis::Commands::Search::Asc.new("@t2"), Redis::Commands::Search::Desc.new("@t1"))

    res = r.ft_aggregate(@index_name, req)
    assert_equal ["t2", "a", "t1", "b"], res[1]
    assert_equal ["t2", "b", "t1", "a"], res[2]

    # Test sort_by without SortDirection
    req = Redis::Commands::Search::AggregateRequest.new("*").sort_by("@t1")
    res = r.ft_aggregate(@index_name, req)
    assert_equal ["t1", "a"], res[1]
    assert_equal ["t1", "b"], res[2]

    # Test sort_by with max
    req = Redis::Commands::Search::AggregateRequest.new("*").sort_by("@t1", max: 1)
    res = r.ft_aggregate(@index_name, req)
    assert_equal 1, res.size - 1 # 1 result row

    # Test limit
    req = Redis::Commands::Search::AggregateRequest.new("*").sort_by("@t1").limit(1, 1)
    res = r.ft_aggregate(@index_name, req)
    assert_equal 1, res.size - 1 # 1 result row
    assert_equal ["t1", "b"], res[1]
  end

  def test_aggregations_load
    schema = Schema.build do
      text_field :t1
      text_field :t2
    end
    r.create_index(@index_name, schema, prefix: "loadtest")

    r.hset("loadtest:doc1", { "t1" => "hello", "t2" => "world" })
    wait_for_index(@index_name)

    # Load t1
    req = Redis::Commands::Search::AggregateRequest.new("*").load("t1")
    res = r.ft_aggregate(@index_name, req)
    assert_equal ["t1", "hello"], res[1]

    # Load t2
    req = Redis::Commands::Search::AggregateRequest.new("*").load("t2")
    res = r.ft_aggregate(@index_name, req)
    assert_equal ["t2", "world"], res[1]

    # Load all
    req = Redis::Commands::Search::AggregateRequest.new("*").load
    res = r.ft_aggregate(@index_name, req)
    assert_equal ["t1", "hello", "t2", "world"], res[1]
  end
end
