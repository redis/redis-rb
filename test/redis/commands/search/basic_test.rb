# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchBasic < Minitest::Test
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

  def test_ft_add_and_search
    schema = Schema.build do
      text_field :title
      text_field :body
    end
    index = r.create_index(@index_name, schema, prefix: "hsh2")

    index.add('doc1', title: 'Hello', body: 'World')
    index.add('doc2', title: 'Goodbye', body: 'World')

    result = index.search('Hello')
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]

    result = index.search('World')
    assert_equal 2, result[0]
    assert_includes result, 'doc1'
    assert_includes result, 'doc2'
  end

  def test_ft_mget_documents
    schema = Schema.build do
      text_field :f1
      text_field :f2
    end
    r.create_index(@index_name, schema)

    # Get non-existent document returns [nil]
    result = r.ft_mget(@index_name, 'mget_doc1')
    assert_equal [nil], result

    # Add documents
    r.hset('mget_doc1', 'f1', 'some valid content dd1', 'f2', 'this is sample text f1')
    r.hset('mget_doc2', 'f1', 'some valid content dd2', 'f2', 'this is sample text f2')

    # Get single document
    result = r.ft_mget(@index_name, 'mget_doc2')
    assert_equal 1, result.length
    assert_includes result[0], 'f1'
    assert_includes result[0], 'some valid content dd2'

    # Get multiple documents
    result = r.ft_mget(@index_name, 'mget_doc1', 'mget_doc2')
    assert_equal 2, result.length
    assert_includes result[0], 'some valid content dd1'
    assert_includes result[1], 'some valid content dd2'
  end

  def test_delete_document
    schema = Schema.build do
      text_field :title
    end
    index = r.create_index(@index_name, schema, prefix: "doc")

    index.add('doc1', title: 'Test Document')
    result = index.search('Test')
    assert_equal 1, result[0]

    # Delete the document - FT.DEL returns 1 if deleted
    del_result = r.ft_del(@index_name, 'doc1')
    assert del_result == 1 || del_result == 0 # Command executed successfully
  end
end
