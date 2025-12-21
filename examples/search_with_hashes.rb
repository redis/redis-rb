# frozen_string_literal: true

require 'redis'
require_relative '../lib/redis/commands/search'

class SearchWithHashes
  include Redis::Commands::Search

  def initialize(host: 'localhost', port: 6379)
    @redis = Redis.new(host: host, port: port)
    @redis.extend(Redis::Commands::Search)
  end

  def run
    # Define print_search_results as a lambda
    print_search_results = lambda do |results|
      total = results[0]
      puts "Total results: #{total}"
      results[1..-1].each_slice(2) do |id, fields|
        puts "ID: #{id}"
        fields.each_slice(2) { |k, v| puts "  #{k}: #{v}" }
        puts
      end
    end

    # Create the index
    index_name = "user-index"
    begin
      @redis.ft_dropindex(index_name, delete_documents: true)
    rescue Redis::CommandError
      puts "Index doesn't exist, creating new one"
    end

    schema = Schema.build do
      text_field :name, sortable: true
      numeric_field :age, sortable: true
      tag_field :city, sortable: true
      text_field :email, sortable: true
    end

    index = @redis.create_index(index_name, schema, storage_type: 'hash', prefix: 'user')

    # Add sample data
    users = [
      { id: "user:1", name: "John Doe", email: "john@example.com", age: 30, city: "New York" },
      { id: "user:2", name: "Jane Smith", email: "jane@example.com", age: 28, city: "Los Angeles" },
      { id: "user:3", name: "Bob Johnson", email: "bob@example.com", age: 35, city: "Chicago" },
      { id: "user:4", name: "Alice Brown", email: "alice@example.com", age: 32, city: "New York" }
    ]

    users.each do |user|
      index.add(user[:id], **user.reject { |k, _| k == :id })
    end

    puts "1. Simple search"
    results = index.search(Query.new("John"))
    print_search_results.call(results)

    puts "\n2. Search with numeric filter"
    results = index.search(Query.build { numeric(:age).between(30, 35) })
    print_search_results.call(results)

    puts "\n3. Search with tag filter"
    results = index.search(Query.build { tag(:city).eq("New York") })
    print_search_results.call(results)

    puts "\n4. Complex query"
    results = index.search(Query.build do
      and_ do
        text(:name).match("John")
        tag(:city).eq("New York")
        numeric(:age).between(30, 35)
      end
    end)
    print_search_results.call(results)

    puts "\n5. Sorted search"
    results = index.search(Query.new("*").sort_by(:age, :desc))
    print_search_results.call(results)

    puts "\n6. Search with return fields"
    results = index.search(Query.new("*").return(:name, :age))
    print_search_results.call(results)

    puts "\n7. Aggregation"
    agg_query = "*"
    agg_args = [
      "GROUPBY", 1, "@city",
      "REDUCE", "COUNT", 0, "AS", "count",
      "SORTBY", 2, "@count", "DESC"
    ]
    results = index.aggregate(agg_query, *agg_args)
    puts "Aggregation results:"
    results[1..-1].each do |group|
      puts "#{group[1]}: #{group[3]} users"
    end

    puts "\n8. Fuzzy search"
    results = index.search(Query.new("%johson%"))
    print_search_results.call(results)

    puts "\n9. Prefix search"
    results = index.search(Query.new("jo*"))
    print_search_results.call(results)

    puts "\n10. Pagination"
    page_size = 2
    page = 1
    results = index.search(Query.new("*").paging((page - 1) * page_size, page_size))
    puts "Page #{page}:"
    print_search_results.call(results)

    # Clean up
    index.drop(delete_documents: true)
  end
end

# Run the example
SearchWithHashes.new.run
