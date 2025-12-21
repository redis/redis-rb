#!/usr/bin/env ruby
# frozen_string_literal: true

# Redis Search Aggregations Example
#
# This example demonstrates Redis Search aggregation and analytics capabilities including:
# - FT.AGGREGATE with various reducers (COUNT, SUM, AVG, MIN, MAX)
# - GROUPBY operations with multiple reducers
# - APPLY transformations and expressions
# - SORTBY for ordering results
# - LIMIT for pagination
# - FILTER for conditional filtering
# - Complex aggregation pipelines
#
# Run this example with: ruby examples/search_aggregations.rb

require 'redis'
require 'json'
require_relative '../lib/redis/commands/json'
require_relative '../lib/redis/commands/search'

# Connect to Redis
redis = Redis.new(host: 'localhost', port: 6400)
redis.extend(Redis::Commands::JSON)
redis.extend(Redis::Commands::Search)

# Clean up any existing index
begin
  redis.ft_dropindex('idx:bicycle', delete_documents: true)
rescue Redis::CommandError
  # Index doesn't exist, continue
end

# Create index
schema = Redis::Commands::Search::Schema.build do
  text_field '$.brand', as: 'brand'
  text_field '$.model', as: 'model'
  text_field '$.description', as: 'description'
  numeric_field '$.price', as: 'price'
  tag_field '$.condition', as: 'condition'
end

definition = Redis::Commands::Search::IndexDefinition.new(
  prefix: ['bicycle:'],
  index_type: Redis::Commands::Search::IndexType::JSON
)

redis.create_index('idx:bicycle', schema, definition: definition)

# Bicycle data
bicycle_data = [
  {
    brand: 'Velorim',
    model: 'Jigger',
    price: 270,
    description: 'Small and powerful, the Jigger is the best ride for the smallest of tikes!',
    condition: 'new'
  },
  {
    brand: 'Bicyk',
    model: 'Hillcraft',
    price: 1200,
    description: 'Kids want to ride with as little weight as possible.',
    condition: 'used'
  },
  {
    brand: 'Nord',
    model: 'Chook air 5',
    price: 815,
    description: 'The Chook Air 5 gives kids aged six years and older a durable bike.',
    condition: 'used'
  },
  {
    brand: 'Eva',
    model: 'Eva 291',
    price: 3400,
    description: 'The sister company to Nord, Eva launched in 2005.',
    condition: 'used'
  },
  {
    brand: 'Noka Bikes',
    model: 'Kahuna',
    price: 3200,
    description: 'Whether you want to try your hand at XC racing.',
    condition: 'used'
  },
  {
    brand: 'Breakout',
    model: 'XBN 2.1 Alloy',
    price: 810,
    description: 'The XBN 2.1 Alloy is our entry-level road bike.',
    condition: 'new'
  },
  {
    brand: 'ScramBikes',
    model: 'WattBike',
    price: 2300,
    description: 'The WattBike is the best e-bike for people who still feel young at heart.',
    condition: 'new'
  },
  {
    brand: 'Peaknetic',
    model: 'Secto',
    price: 430,
    description: 'If you struggle with stiff fingers or a kinked neck.',
    condition: 'new'
  },
  {
    brand: 'nHill',
    model: 'Summit',
    price: 1200,
    description: 'This budget mountain bike from nHill performs well.',
    condition: 'new'
  },
  {
    brand: 'BikeShind',
    model: 'ThrillCycle',
    price: 815,
    description: 'An artsy, retro-inspired bicycle.',
    condition: 'refurbished'
  }
]

# Add bicycle documents
bicycle_data.each_with_index do |bike, i|
  redis.json_set("bicycle:#{i}", '$', bike)
end

puts "Added #{bicycle_data.length} bicycle documents\n\n"

# STEP_START agg1
# Example 1: APPLY transformation - Calculate discounted price for new bicycles
puts "Example 1: APPLY transformation - Calculate discounted price for new bicycles"
req1 = Redis::Commands::Search::AggregateRequest.new('@condition:{new}')
                                                .load('__key', 'price')
                                                .apply(discounted: '@price - (@price * 0.1)')

res1 = redis.ft_aggregate('idx:bicycle', req1)
puts "Total results: #{res1[0]}"
puts "Results:"
(1...res1.length).each do |i|
  row = res1[i]
  puts "  Key: #{row[row.index('__key') + 1]}, " \
       "Price: #{row[row.index('price') + 1]}, " \
       "Discounted: #{row[row.index('discounted') + 1]}"
end
puts
# STEP_END

# STEP_START agg2
# Example 2: GROUPBY with SUM reducer - Count affordable bikes by condition
puts "Example 2: GROUPBY with SUM reducer - Count affordable bikes by condition"
req2 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('price')
                                                .apply(price_category: '@price<1000')
                                                .group_by('@condition', Redis::Commands::Search::Reducers.sum('@price_category').as('num_affordable'))

res2 = redis.ft_aggregate('idx:bicycle', req2)
puts "Total results: #{res2[0]}"
puts "Results:"
(1...res2.length).each do |i|
  row = res2[i]
  puts "  Condition: #{row[row.index('condition') + 1]}, " \
       "Num Affordable: #{row[row.index('num_affordable') + 1]}"
end
puts
# STEP_END

# STEP_START agg3
# Example 3: GROUPBY with COUNT reducer - Count total bicycles
puts "Example 3: GROUPBY with COUNT reducer - Count total bicycles"
req3 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .apply(type: "'bicycle'")
                                                .group_by('@type', Redis::Commands::Search::Reducers.count.as('num_total'))

res3 = redis.ft_aggregate('idx:bicycle', req3)
puts "Total results: #{res3[0]}"
puts "Results:"
(1...res3.length).each do |i|
  row = res3[i]
  puts "  Type: #{row[row.index('type') + 1]}, " \
       "Total: #{row[row.index('num_total') + 1]}"
end
puts
# STEP_END

# STEP_START agg4
# Example 4: GROUPBY with TOLIST reducer - List bicycles by condition
puts "Example 4: GROUPBY with TOLIST reducer - List bicycles by condition"
req4 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('__key')
                                                .group_by('@condition', Redis::Commands::Search::Reducers.tolist('__key').as('bicycles'))

res4 = redis.ft_aggregate('idx:bicycle', req4)
puts "Total results: #{res4[0]}"
puts "Results:"
(1...res4.length).each do |i|
  row = res4[i]
  condition_idx = row.index('condition')
  bicycles_idx = row.index('bicycles')
  puts "  Condition: #{row[condition_idx + 1]}"
  puts "  Bicycles: #{row[bicycles_idx + 1]}"
end
puts
# STEP_END

# STEP_START agg5
# Example 5: GROUPBY with multiple reducers - Statistics by condition
puts "Example 5: GROUPBY with multiple reducers - Statistics by condition"
req5 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('price')
                                                .group_by('@condition',
                                                          Redis::Commands::Search::Reducers.count.as('count'),
                                                          Redis::Commands::Search::Reducers.sum('@price').as('total_price'),
                                                          Redis::Commands::Search::Reducers.avg('@price').as('avg_price'),
                                                          Redis::Commands::Search::Reducers.min('@price').as('min_price'),
                                                          Redis::Commands::Search::Reducers.max('@price').as('max_price'))

res5 = redis.ft_aggregate('idx:bicycle', req5)
puts "Total results: #{res5[0]}"
puts "Results:"
(1...res5.length).each do |i|
  row = res5[i]
  puts "  Condition: #{row[row.index('condition') + 1]}"
  puts "    Count: #{row[row.index('count') + 1]}"
  puts "    Total Price: #{row[row.index('total_price') + 1]}"
  puts "    Avg Price: #{row[row.index('avg_price') + 1]}"
  puts "    Min Price: #{row[row.index('min_price') + 1]}"
  puts "    Max Price: #{row[row.index('max_price') + 1]}"
end
puts
# STEP_END

# STEP_START agg6
# Example 6: SORTBY - Sort results by price descending
puts "Example 6: SORTBY - Sort results by price descending"
req6 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('__key', 'price', 'brand')
                                                .sort_by(Redis::Commands::Search::Desc.new('@price'))

res6 = redis.ft_aggregate('idx:bicycle', req6)
puts "Total results: #{res6[0]}"
puts "Results (top 5):"
(1...[res6.length, 6].min).each do |i|
  row = res6[i]
  puts "  Brand: #{row[row.index('brand') + 1]}, " \
       "Price: #{row[row.index('price') + 1]}"
end
puts
# STEP_END

# STEP_START agg7
# Example 7: LIMIT - Paginate results
puts "Example 7: LIMIT - Paginate results"
req7 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('__key', 'price', 'brand')
                                                .sort_by(Redis::Commands::Search::Asc.new('@price'))
                                                .limit(2, 3) # Skip 2, return 3

res7 = redis.ft_aggregate('idx:bicycle', req7)
puts "Total results: #{res7[0]}"
puts "Results (offset 2, limit 3):"
(1...res7.length).each do |i|
  row = res7[i]
  puts "  Brand: #{row[row.index('brand') + 1]}, " \
       "Price: #{row[row.index('price') + 1]}"
end
puts
# STEP_END

# STEP_START agg8
# Example 8: FILTER - Filter aggregated results
puts "Example 8: FILTER - Filter aggregated results"
req8 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('price')
                                                .group_by('@condition',
                                                          Redis::Commands::Search::Reducers.avg('@price').as('avg_price'))
                                                .filter('@avg_price > 1000')

res8 = redis.ft_aggregate('idx:bicycle', req8)
puts "Total results: #{res8[0]}"
puts "Results (conditions with avg price > 1000):"
(1...res8.length).each do |i|
  row = res8[i]
  puts "  Condition: #{row[row.index('condition') + 1]}, " \
       "Avg Price: #{row[row.index('avg_price') + 1]}"
end
puts
# STEP_END

# STEP_START agg9
# Example 9: Complex aggregation pipeline
puts "Example 9: Complex aggregation pipeline - Price analysis by condition"
req9 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('price', 'brand')
                                                .apply(price_range: '@price >= 1000 ? "high" : "low"')
                                                .group_by(['@condition', '@price_range'],
                                                          Redis::Commands::Search::Reducers.count.as('count'),
                                                          Redis::Commands::Search::Reducers.avg('@price').as('avg_price'))
                                                .sort_by(Redis::Commands::Search::Desc.new('@count'))

res9 = redis.ft_aggregate('idx:bicycle', req9)
puts "Total results: #{res9[0]}"
puts "Results:"
(1...res9.length).each do |i|
  row = res9[i]
  puts "  Condition: #{row[row.index('condition') + 1]}, " \
       "Price Range: #{row[row.index('price_range') + 1]}, " \
       "Count: #{row[row.index('count') + 1]}, " \
       "Avg Price: #{row[row.index('avg_price') + 1]}"
end
puts
# STEP_END

puts "All aggregation examples completed successfully!"
