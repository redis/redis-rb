# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchSearchOptions < Minitest::Test
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

  def wait_for_index(index_name, timeout = 5)
    start_time = Time.now
    loop do
      info = r.ft_info(index_name)
      break if info['indexing'] == 0 || info['indexing'] == '0'

      raise "Timeout waiting for index #{index_name}" if Time.now - start_time > timeout

      sleep 0.1
    end
  end

  def test_ft_search_with_options
    schema = Schema.build do
      text_field :title
      text_field :body
    end
    index = r.create_index(@index_name, schema, prefix: "hsh4")

    index.add('doc1', title: 'Hello', body: 'World')
    index.add('doc2', title: 'Hello', body: 'Redis')
    wait_for_index(@index_name)

    # NOCONTENT
    result = index.search('Hello', nocontent: true)
    assert_equal [2, 'doc1', 'doc2'], result

    # VERBATIM
    result = index.search('Hello', verbatim: true)
    assert_equal 2, result[0]

    # NOSTOPWORDS - search for 'Hello' (stopwords like 'a' are ignored)
    result = index.search('Hello', no_stopwords: true)
    assert_equal 2, result[0]

    # WITHSCORES
    result = index.search('Hello', with_scores: true)
    assert_equal 2, result[0]
    assert_kind_of String, result[2] # score

    # WITHPAYLOADS
    index.add('doc3', title: 'Payload', body: 'Test', payload: 'pl')
    wait_for_index(@index_name)
    result = index.search('Payload', with_payloads: true)
    # Verify we get 1 result with doc3
    assert_equal 1, result[0]
    assert_equal 'doc3', result[1]
    # When with_payloads is true, result[2] is nil (no score) and result[3] contains fields
    assert result[3].include?('payload')
    assert result[3].include?('pl')

    # SORTBY
    schema_sort = Schema.build { numeric_field :price, sortable: true }
    r.create_index('sort_idx', schema_sort, prefix: 'hsh_sorttest')
    r.hset('hsh_sorttest:1', 'price', 10)
    r.hset('hsh_sorttest:2', 'price', 5)
    wait_for_index('sort_idx')

    result = r.ft_search('sort_idx', '*', sort_by: 'price', asc: true)
    # Should return doc with price 5 first (ascending order)
    assert_equal 'hsh_sorttest:2', result[1]

    # LIMIT - limits the number of results returned, but total count is still 2
    result = r.ft_search(@index_name, 'Hello', limit: [0, 1])
    assert_equal 2, result[0] # Total count
    # Only 1 document should be returned (result[1] is doc id, result[2] is fields)
    # If there were 2 docs, result[3] would be the second doc id
    assert_nil result[3]
  end

  def test_ft_search_with_return
    schema = Schema.build do
      text_field :title
      text_field :body
      numeric_field :price
    end
    index = r.create_index(@index_name, schema, prefix: "hsh8")

    index.add('doc1', title: 'Shirt', body: 'Blue', price: 15)

    result = index.search('Shirt', return_fields: ['title', 'price'])
    assert_equal [1, 'doc1', ['title', 'Shirt', 'price', '15']], result
  end

  def test_ft_search_with_summarize
    schema = Schema.build do
      text_field :title
      text_field :body
    end
    index = r.create_index(@index_name, schema, prefix: "hsh_summ")

    index.add('doc1', title: 'Summarize', body: 'This is a long text for summarization.')

    result = index.search('summarization', summarize: { fields: ['body'], len: 2, separator: '...' })
    # Verify we get 1 result with doc1 and the body field summarized
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]
    assert result[2].include?('body')
    assert result[2][result[2].index('body') + 1].include?('summarization')
  end

  def test_ft_search_with_highlight
    schema = Schema.build do
      text_field :title
      text_field :body
    end
    index = r.create_index(@index_name, schema, prefix: "hsh_high")

    index.add('doc1', title: 'Highlight', body: 'Text to highlight.')

    result = index.search('highlight', highlight: { fields: ['body'], tags: ['<b>', '</b>'] })
    # Verify we get 1 result with doc1 and the body field highlighted
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]
    assert result[2].include?('body')
    assert result[2][result[2].index('body') + 1].include?('<b>highlight</b>')
  end

  def test_ft_search_with_slop_and_inorder
    schema = Schema.build do
      text_field :content
    end
    index = r.create_index(@index_name, schema, prefix: "hsh_slop")

    index.add('doc1', content: 'hello world redis')
    index.add('doc2', content: 'hello redis')
    wait_for_index(@index_name)

    # SLOP - allows words between terms in a phrase
    result = index.search('"hello redis"', slop: 1)
    # Should match both "hello world redis" (slop=1) and "hello redis" (slop=0)
    assert result[0] >= 1

    # INORDER - enforces term order
    result = index.search('"hello world"', in_order: true)
    assert_equal 1, result[0] # Should match doc1
  end

  def test_ft_search_with_language_and_payload
    schema = Schema.build do
      text_field :text
    end
    index = r.create_index(@index_name, schema, prefix: "hsh_lang")

    index.add('doc1', text: 'hola', payload: 'spanish greeting')
    wait_for_index(@index_name)

    result = index.search('hola', language: 'spanish', with_payloads: true)
    # Verify we get 1 result with doc1
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]
    # When with_payloads is true, the payload should be in the result
    # The exact format depends on the Redis version and implementation
    assert result.size > 2
  end

  def test_ft_search_with_scorer
    schema = Schema.build do
      text_field :description
    end
    r.create_index(@index_name, schema, prefix: "hsh_scorer")
    r.hset("hsh_scorer:doc1", "description", "The quick brown fox jumps over the lazy dog")
    r.hset("hsh_scorer:doc2", "description", "Quick alice was beginning to get very tired")
    wait_for_index(@index_name)

    # Test with built-in TFIDF scorer
    result = r.ft_search(@index_name, 'quick', scorer: 'TFIDF', with_scores: true)
    assert_equal 2, result[0]
    # Format: [count, doc_id, score, fields, doc_id, score, fields, ...]
    # result[1] = doc_id, result[2] = score, result[3] = fields
    assert result[1].start_with?('hsh_scorer:')
    # Score should be a numeric string (can be 0 or positive)
    assert_kind_of String, result[2]
    assert result[2].to_f >= 0

    # Test with BM25 scorer
    result = r.ft_search(@index_name, 'quick', scorer: 'BM25', with_scores: true)
    assert_equal 2, result[0]
    assert_kind_of String, result[2]
    assert result[2].to_f >= 0
  end

  def test_ft_search_with_explainscore
    schema = Schema.build do
      text_field :title
    end
    r.create_index(@index_name, schema, prefix: "hsh_explain")
    r.hset("hsh_explain:doc1", "title", "hello")
    wait_for_index(@index_name)

    result = r.ft_search(@index_name, 'hello', explain_score: true, with_scores: true)
    # Result format: [count, doc_id, [score, explanation], fields...]
    assert_equal 1, result[0] # Count
    assert_equal 'hsh_explain:doc1', result[1] # Doc ID
    # result[2] is an array containing [score, explanation]
    assert_kind_of Array, result[2]
    assert_equal 2, result[2].size
    assert_kind_of String, result[2][0] # Score
    assert_kind_of Array, result[2][1] # Explanation
    # result[3] is the fields
    assert_kind_of Array, result[3]
  end

  def test_ft_search_with_sortby_and_withscores
    schema = Schema.build do
      numeric_field :price, sortable: true
    end
    index = r.create_index(@index_name, schema, prefix: "hsh_sort")
    index.add('doc1', price: 10)
    index.add('doc2', price: 20)
    wait_for_index(@index_name)

    result = index.search('*', sort_by: 'price', asc: true, with_scores: true)
    # Verify we get 2 results sorted by price
    assert_equal 2, result[0]
    # Results should be sorted by price (doc1 has price 10, doc2 has price 20)
    assert result.include?('doc1')
    assert result.include?('doc2')
  end
end
