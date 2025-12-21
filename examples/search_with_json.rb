# frozen_string_literal: true

require 'redis'
require 'json'
require_relative '../lib/redis/commands/json'
require_relative '../lib/redis/commands/search'

class SearchWithJSON
  include Redis::Commands::Search
  include Redis::Commands::JSON

  def initialize(host: 'localhost', port: 6379)
    @redis = Redis.new(host: host, port: port)
    @redis.extend(Redis::Commands::JSON)
    @redis.extend(Redis::Commands::Search)
  end

  def run
    index_name = 'idx:users'
    schema = Schema.build do
      text_field '$.user.name', as: 'name'
      tag_field '$.user.city', as: 'city'
      numeric_field '$.user.age', as: 'age'
    end

    begin
      @redis.ft_dropindex(index_name, delete_documents: true)
    rescue Redis::CommandError
      puts "Index doesn't exist, creating new one"
    end

    index = @redis.create_index(index_name, schema, storage_type: 'JSON', prefix: 'user')

    @redis.json_set('user:1', '$', { user: { name: 'John Doe', city: 'New York', age: 30 } })
    @redis.json_set('user:2', '$', { user: { name: 'Jane Smith', city: 'Los Angeles', age: 25 } })
    @redis.json_set('user:3', '$', { user: { name: 'Bob Johnson', city: 'Chicago', age: 35 } })

    puts "1. Simple search"
    results = index.search(Query.new("John"))
    print_results(results)

    puts "\n2. Search with numeric filter"
    results = index.search(Query.build { numeric(:age).between(30, 35) })
    print_results(results)

    puts "\n3. Search with tag filter"
    results = index.search(Query.build { tag(:city).eq("New York") })
    print_results(results)

    puts "\n4. Complex query"
    results = index.search(Query.build do
      and_ do
        text(:name).match("John")
        tag(:city).eq("New York")
        numeric(:age).between(30, 35)
      end
    end)
    print_results(results)

    puts "\n5. Sorted search"
    results = index.search(Query.new("*").sort_by(:age, :desc))
    print_results(results)

    puts "\n6. Search with return fields"
    results = index.search(Query.new("*").return(:name, :age))
    print_results(results)

    puts "\n7. Aggregation"
    agg_query = "*"
    agg_args = [
      "GROUPBY", 1, "@city",
      "REDUCE", "COUNT", 0, "AS", "count",
      "SORTBY", 2, "@count", "DESC"
    ]
    agg_results = index.aggregate(agg_query, *agg_args)
    print_aggregation(agg_results)

    puts "\n8. Fuzzy search"
    results = index.search(Query.new("%johson%"))
    print_results(results)

    puts "\n9. Prefix search"
    results = index.search(Query.new("jo*"))
    print_results(results)

    puts "\n10. Pagination"
    page_size = 2
    page = 1
    results = index.search(Query.new("*").paging((page - 1) * page_size, page_size))
    puts "Page #{page}:"
    print_results(results)

    # Clean up
    index.drop(delete_documents: true)
  end

  private

  def print_results(res)
    puts "Total results: #{res[0]}"
    res[1..-1].each_slice(2) do |id, fields|
      puts "ID: #{id}"
      if fields.is_a?(Array)
        fields.each_slice(2) do |key, value|
          if key == "$"
            begin
              json = JSON.parse(value)
              user = json['user']
              puts "  Name: #{user['name']}"
              puts "  City: #{user['city']}"
              puts "  Age: #{user['age']}"
            rescue JSON::ParserError => e
              puts "Error parsing JSON: #{e.message}"
              puts "Raw JSON string: #{value}"
            end
          else
            puts "  #{key}: #{value}"
          end
        end
      else
        puts "  Fields: #{fields.inspect}"
      end
      puts
    end
  end

  def print_aggregation(res)
    puts "Aggregation results:"
    res[1..-1].each do |group|
      puts "#{group[1]}: #{group[3]} users"
    end
  end
end

SearchWithJSON.new.run
