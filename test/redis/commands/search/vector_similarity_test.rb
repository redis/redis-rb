# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchVectorSimilarity < Minitest::Test
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

  def test_vector_similarity
    schema = Schema.build do
      vector_field :embedding, :flat, type: :float32, dim: 4, distance_metric: :l2
      tag_field :tag
    end
    r.create_index(@index_name, schema)

    docs = {
      'doc1' => { embedding: [0.1, 0.9, 0.2, 0.8].pack('f*'), tag: 'a' },
      'doc2' => { embedding: [0.2, 0.8, 0.3, 0.7].pack('f*'), tag: 'b' },
      'doc3' => { embedding: [0.8, 0.2, 0.7, 0.3].pack('f*'), tag: 'c' }
    }
    docs.each { |id, fields| r.hset(id, fields) }

    query_vector = [0.15, 0.85, 0.25, 0.75].pack('f*')

    # Basic KNN
    result = r.ft_search(@index_name, '(*)=>[KNN 2 @embedding $query_vector]',
                         params: { query_vector: query_vector },
                         dialect: 2)
    assert_equal 2, result[0]
    assert_includes ['doc1', 'doc2'], result[1]
    assert_includes ['doc1', 'doc2'], result[3]

    # KNN with pre-filter
    result = r.ft_search(@index_name, '(@tag:{a})=>[KNN 1 @embedding $query_vector]',
                         params: { query_vector: query_vector }, dialect: 2)
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]
  end
end
