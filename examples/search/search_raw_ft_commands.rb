#!/usr/bin/env ruby
# frozen_string_literal: true

# Redis Query Engine - Raw FT.* Commands (the low-level alternative)
#
# The other search_*.rb examples use the high-level Index API
# (Redis::Commands::Search::Index) as the recommended way to work with the Query Engine.
# This file shows the SAME operations using the thin `ft_*` command methods directly.
#
# When to prefer the raw commands:
# - You want a one-to-one mirror of the Redis command reference / redis-cli.
# - You need a flag or query-syntax feature the builders don't expose yet.
# - You're writing a quick script and don't need the Index/Query/Schema objects.
#
# Both styles go through the same connection and return the same reshaped result objects
# (SearchResult / AggregateResult), so you can mix them freely.
#
# Run with: ruby examples/search_raw_ft_commands.rb

require 'redis'
require 'json'

redis = Redis.new(host: 'localhost', port: 6379)

# Clean up any existing index
begin
  redis.ft_dropindex('idx:movies', delete_documents: true)
rescue Redis::CommandError
  # Index doesn't exist, continue
end

# STEP_START create_index
# A Schema object still describes the fields, but FT.CREATE is issued via ft_create.
schema = Redis::Commands::Search::Schema.build do
  text_field :title, sortable: true
  tag_field :genre
  numeric_field :rating, sortable: true
  numeric_field :year
end

redis.ft_create('idx:movies', schema, storage_type: 'HASH', prefix: 'movie')
# STEP_END

# STEP_START add_documents
# Documents are plain hashes written with HSET (no Index#add helper here).
movies = [
  { title: 'The Matrix', genre: 'scifi', rating: 8.7, year: 1999 },
  { title: 'The Matrix Reloaded', genre: 'scifi', rating: 7.2, year: 2003 },
  { title: 'Inception', genre: 'scifi', rating: 8.8, year: 2010 },
  { title: 'The Godfather', genre: 'crime', rating: 9.2, year: 1972 },
  { title: 'Pulp Fiction', genre: 'crime', rating: 8.9, year: 1994 }
]
movies.each_with_index do |movie, i|
  redis.hset("movie:#{i}", movie)
end
# STEP_END

# STEP_START search
# FT.SEARCH via ft_search. Returns a Search::SearchResult.
result = redis.ft_search('idx:movies', '@genre:{scifi}')
puts "scifi movies: #{result.total}"
result.each { |doc| puts "  #{doc.id}: #{doc['title']} (#{doc['year']})" }
# STEP_END

# STEP_START search_with_options
# Options map straight to FT.SEARCH tokens (RETURN, SORTBY, LIMIT, ...).
result = redis.ft_search('idx:movies', '@rating:[8.5 +inf]',
                         return: %w[title rating],
                         sortby: %w[rating DESC],
                         limit: [0, 3])
puts "\ntop-rated (>= 8.5):"
result.each { |doc| puts "  #{doc['title']} - #{doc['rating']}" }
# STEP_END

# STEP_START search_with_params
# Parameterized query (PARAMS). DIALECT 2 is applied by default.
result = redis.ft_search('idx:movies', '@year:[$from $to]',
                         params: { from: 1990, to: 2005 })
puts "\nreleased 1990-2005: #{result.total}"
# STEP_END

# STEP_START aggregate
# FT.AGGREGATE via ft_aggregate with raw pipeline tokens. Returns a Search::AggregateResult.
agg = redis.ft_aggregate('idx:movies', '*',
                         'GROUPBY', 1, '@genre',
                         'REDUCE', 'COUNT', 0, 'AS', 'count',
                         'REDUCE', 'AVG', 1, '@rating', 'AS', 'avg_rating')
puts "\nby genre:"
agg.each { |row| puts "  #{row['genre']}: #{row['count']} movies, avg #{row['avg_rating']}" }
# STEP_END

# STEP_START info
# FT.INFO via ft_info returns a Hash of index metadata.
info = redis.ft_info('idx:movies')
puts "\nindex '#{info['index_name']}' has #{info['num_docs']} documents"
# STEP_END

# STEP_START explain
# FT.EXPLAIN returns the parsed query plan as a String.
puts "\nquery plan:"
puts redis.ft_explain('idx:movies', '@genre:{scifi} @rating:[8 9]')
# STEP_END

puts "\n=== Raw FT.* Commands Complete ==="
