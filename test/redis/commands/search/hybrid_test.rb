# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchHybrid < Minitest::Test
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

  def test_hybrid_search
    schema = Schema.build do
      text_field :title
      vector_field :embedding, :flat, type: :float32, dim: 2, distance_metric: :cosine
    end
    r.create_index(@index_name, schema)

    r.hset('doc1', title: 'foo', embedding: [0.1, 0.9].pack('f*'))
    r.hset('doc2', title: 'bar', embedding: [0.8, 0.2].pack('f*'))

    # Basic KNN search (not truly hybrid, just vector similarity)
    result = r.ft_search(@index_name, '(*)=>[KNN 2 @embedding $query_vector]',
                         params: { query_vector: [0.1, 0.9].pack('f*') },
                         dialect: 2)
    assert_equal 2, result[0]
  end

  def test_hybrid_search_with_optional_parameters
    schema = Schema.build do
      text_field :title
      vector_field :embedding, :flat, type: :float32, dim: 2, distance_metric: :cosine
    end
    r.create_index(@index_name, schema)

    r.hset('doc1', title: 'foo', embedding: [0.1, 0.9].pack('f*'))
    r.hset('doc2', title: 'bar', embedding: [0.8, 0.2].pack('f*'))

    # Hybrid search: text filter + KNN
    result = r.ft_search(@index_name, '(@title:foo)=>[KNN 1 @embedding $query_vector]',
                         params: { query_vector: [0.1, 0.9].pack('f*') },
                         limit: [0, 1],
                         sortby: ['title', 'ASC'],
                         return: %w[title],
                         withscores: true,
                         dialect: 2)
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]
  end
end
