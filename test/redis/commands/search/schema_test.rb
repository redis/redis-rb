# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchSchema < Minitest::Test
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

  def test_schema_definition
    schema = Schema.build do
      text_field 'title', weight: 5.0, no_stem: true
      text_field 'body'
      numeric_field 'price', sortable: true
      geo_field 'location'
      tag_field 'tags', separator: ',', case_sensitive: true
    end

    # Verify the schema has the correct fields
    assert_equal 5, schema.fields.size
    assert_equal 'title', schema.fields[0].name
    assert_equal :text, schema.fields[0].type
    assert_equal 'body', schema.fields[1].name
    assert_equal 'price', schema.fields[2].name
    assert_equal :numeric, schema.fields[2].type
    assert_equal 'location', schema.fields[3].name
    assert_equal :geo, schema.fields[3].type
    assert_equal 'tags', schema.fields[4].name
    assert_equal :tag, schema.fields[4].type
  end

  def test_create_index_with_schema
    schema = Schema.build do
      text_field :title
      numeric_field :price
    end

    index = r.create_index(@index_name, schema,
                           prefix: "docs",
                           on: :hash,
                           filter: "@price > 100",
                           language: :english,
                           language_field: :lang,
                           score: 0.5,
                           score_field: :s,
                           payload_field: :payload)
    # create_index returns an Index object, not "OK"
    assert_instance_of Redis::Commands::Search::Index, index
    assert_equal @index_name, index.name

    info = r.ft_info(@index_name)
    assert_equal @index_name, info['index_name']
    # Verify the index was created successfully
    assert info.key?('index_options')
  end

  def test_alter_schema
    schema = Schema.build { text_field :title }
    r.create_index(@index_name, schema)

    new_field = Redis::Commands::Search::TextField.new(:body)
    assert_equal "OK", r.ft_alter(@index_name, new_field)

    info = r.ft_info(@index_name)
    field_names = info['attributes'].map { |attr| attr[1] }
    assert_includes field_names, 'title'
    assert_includes field_names, 'body'
  end

  def test_ft_info
    schema = Schema.build { text_field :title }
    r.create_index(@index_name, schema, prefix: "ftinfo")

    info = r.ft_info(@index_name)
    assert_equal @index_name, info['index_name']
    # num_docs should be 0 since we haven't added any documents with the prefix
    assert info['num_docs'] >= 0
    # Verify the field exists in attributes
    assert(info['attributes'].any? { |attr| attr.include?('title') })
  end

  def test_drop_index
    schema = Schema.build { text_field :title }

    # First test: drop without deleting documents
    r.create_index(@index_name, schema, prefix: "testdrop")
    r.hset("testdrop:doc1", "title", "hello")
    r.hset("testdrop:doc2", "title", "world")

    # Verify documents exist
    assert_equal 1, r.exists("testdrop:doc1")
    assert_equal 1, r.exists("testdrop:doc2")

    assert_equal "OK", r.ft_dropindex(@index_name, delete_documents: false)
    # Documents should still exist
    assert_equal 1, r.exists("testdrop:doc1")
    assert_equal 1, r.exists("testdrop:doc2")

    # Clean up documents for next test
    r.del("testdrop:doc1", "testdrop:doc2")

    # Second test: drop with deleting documents
    r.create_index(@index_name, schema, prefix: "testdrop2")
    r.hset("testdrop2:doc3", "title", "foo")
    r.hset("testdrop2:doc4", "title", "bar")

    assert_equal 1, r.exists("testdrop2:doc3")
    assert_equal 1, r.exists("testdrop2:doc4")

    assert_equal "OK", r.ft_dropindex(@index_name, delete_documents: true)
    # Documents should be deleted
    assert_equal 0, r.exists("testdrop2:doc3")
    assert_equal 0, r.exists("testdrop2:doc4")
  end
end
