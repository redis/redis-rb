# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchQueryBuilder < Minitest::Test
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

  def test_query_builder
    schema = Schema.build do
      text_field :title
      tag_field :category
      numeric_field :score
    end
    index = r.create_index(@index_name, schema, prefix: "hsh24")

    index.add('doc1', title: 'Hello World', category: 'greeting', score: 0.5)
    index.add('doc2', title: 'Goodbye World', category: 'farewell', score: 1.0)

    query = Query.build do
      and_ do
        tag(:category).eq("greeting")
        text(:title).match("Hel*")
      end
    end
    query.filter(:score, 0.3, "+inf")

    result = index.search(query)
    assert_equal 1, result[0]
    assert_equal 'doc1', result[1]
  end

  def test_query_with_multiple_predicates_anded
    schema = Schema.build do
      text_field :title
      tag_field :category
      numeric_field :score
    end
    index = r.create_index(@index_name, schema, prefix: "hsh26")

    index.add('doc1', title: 'Hello World', category: 'greeting', score: 0.5)
    index.add('doc2', title: 'Hello Redis', category: 'tech', score: 0.8)
    index.add('doc3', title: 'Goodbye World', category: 'farewell', score: 1.0)

    query = Query.build do
      and_ do
        text(:title).match("Hello*")
        tag(:category).eq("tech")
      end
    end
    query.filter(:score, 0.4, 0.9)

    result = index.search(query)
    assert_equal 1, result[0]
    assert_equal 'doc2', result[1]
  end

  def test_query_with_multiple_predicates
    schema = Schema.build do
      text_field :title
      tag_field :category
      numeric_field :score
    end
    index = r.create_index(@index_name, schema, prefix: "hsh26")

    index.add('doc1', title: 'Hello World', category: 'greeting', score: 0.5)
    index.add('doc2', title: 'Hello Redis', category: 'tech', score: 0.8)
    index.add('doc3', title: 'Goodbye World', category: 'farewell', score: 1.0)

    query = Query.build do
      text(:title).match("Hello*")
      tag(:category).eq("tech")
    end
    query.filter(:score, 0.4, 0.9)

    result = index.search(query)
    assert_equal 1, result[0]
    assert_equal 'doc2', result[1]
  end

  def test_query_with_or_predicates
    schema = Schema.build do
      text_field :title
      tag_field :category
    end
    index = r.create_index(@index_name, schema, prefix: "hsh27")

    index.add('doc1', title: 'Hello World', category: 'greeting')
    index.add('doc2', title: 'Hello Redis', category: 'tech')
    index.add('doc3', title: 'Goodbye World', category: 'farewell')

    query = Query.build do
      or_ do
        text(:title).match("Hello*")
        tag(:category).eq("farewell")
      end
    end

    result = index.search(query)
    assert_equal 3, result[0]
    assert_includes result, 'doc1'
    assert_includes result, 'doc2'
    assert_includes result, 'doc3'
  end

  def test_complex_query_with_and_or
    schema = Schema.build do
      text_field :title
      tag_field :category
      numeric_field :score
    end
    index = r.create_index(@index_name, schema, prefix: "hsh28")

    index.add('doc1', title: 'Hello World', category: 'greeting', score: 0.5)
    index.add('doc2', title: 'Hello Redis', category: 'tech', score: 0.8)
    index.add('doc3', title: 'Goodbye World', category: 'farewell', score: 1.0)
    index.add('doc4', title: 'Hello Ruby', category: 'tech', score: 0.9)

    query = Query.build do
      or_ do
        and_ do
          text(:title).match("Hello*")
          tag(:category).eq("tech")
        end
        tag(:category).eq("farewell")
      end
    end
    query.filter(:score, 0.7, "+inf")

    result = index.search(query)
    assert_equal 3, result[0]
    assert_includes result, 'doc2'
    assert_includes result, 'doc3'
    assert_includes result, 'doc4'
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

    index.add('book1', title: 'Redis in Action', category: 'programming', author: 'Josiah Carlson', score: 4.5, year: 2013)
    index.add('book2', title: 'Redis Essentials', category: 'database', author: 'Maxwell Dayvson Da Silva', score: 4.0, year: 2015)
    index.add('book3', title: 'Redis Cookbook', category: 'programming', author: 'Tiago Macedo', score: 3.5, year: 2011)
    index.add('book4', title: 'Learning Redis', category: 'database', author: 'Vinoo Das', score: 4.2, year: 2015)
    index.add('book5', title: 'Redis Applied Design Patterns', category: 'programming', author: 'Arun Chinnachamy', score: 3.8, year: 2014)

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

    assert_equal 2, result[0]
    assert_includes result, 'book1'
    assert_includes result, 'book4'
  end

  def test_query_methods
    schema = Schema.build do
      text_field :title
      tag_field :category
      numeric_field :price
    end
    index = r.create_index(@index_name, schema, prefix: "product")

    index.add('prod1', title: 'iPhone', category: 'electronics', price: 999)
    index.add('prod2', title: 'Galaxy', category: 'electronics', price: 799)
    index.add('prod3', title: 'Book', category: 'literature', price: 15)

    query = Query.new("@category:{electronics}")
                 .filter(:price, 0, 800)
                 .paging(0, 10)
                 .sort_by(:price, :desc)
                 .return(:title, :price)
                 .with_scores

    result = index.search(query)

    assert_equal 1, result[0]
    assert_equal 'prod2', result[1]
    assert_kind_of String, result[2] # score
    assert_equal ['price', '799', 'title', 'Galaxy'], result[3]
  end

  def test_comprehensive_query
    schema = Schema.build do
      text_field :title, weight: 5.0
      tag_field :category
      numeric_field :price, sortable: true
      text_field :description
    end
    index = r.create_index(@index_name, schema, prefix: "comp")

    index.add('prod1', title: 'iPhone 12', category: 'electronics', price: 999, description: 'Latest model')
    index.add('prod2', title: 'Samsung Galaxy', category: 'electronics', price: 799, description: 'Android flagship')
    index.add('prod3', title: 'Kindle', category: 'electronics', price: 129, description: 'E-reader')
    index.add('prod4', title: 'Harry Potter', category: 'books', price: 15, description: 'Fantasy novel')

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
         .with_scores
         .language(:english)
         .slop(0)
         .in_order
         .verbatim
         .no_stopwords

    result = index.search(query)

    assert_equal 3, result[0]

    # Extract document IDs and their corresponding fields
    documents = result[1..-1].each_slice(3).map do |id, _score, fields|
      [id, Hash[*fields]]
    end

    assert_equal 3, documents.length

    document_ids = documents.map { |doc| doc[0] }
    assert_includes document_ids, 'prod1'
    assert_includes document_ids, 'prod2'
    assert_includes document_ids, 'prod3'
    refute_includes document_ids, 'prod4'

    # Check if results are sorted by price in descending order
    prices = documents.map { |doc| doc[1]['price'].to_f }
    assert_equal prices.sort.reverse, prices

    # Verify the order of results
    assert_equal ['prod1', 'prod2', 'prod3'], document_ids
  end
end
