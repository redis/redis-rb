# !/usr/bin/env ruby
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

# Connect to Redis
redis = Redis.new(host: 'localhost', port: 6379)

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

index = redis.create_index('idx:bicycle', schema, definition: definition)

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

res1 = index.aggregate(req1)
puts "Total results: #{res1.size}"
puts "Results:"
res1.each do |row|
  puts "  Key: #{row['__key']}, " \
       "Price: #{row['price']}, " \
       "Discounted: #{row['discounted']}"
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

res2 = index.aggregate(req2)
puts "Total results: #{res2.size}"
puts "Results:"
res2.each do |row|
  puts "  Condition: #{row['condition']}, " \
       "Num Affordable: #{row['num_affordable']}"
end
puts
# STEP_END

# STEP_START agg3
# Example 3: GROUPBY with COUNT reducer - Count total bicycles
puts "Example 3: GROUPBY with COUNT reducer - Count total bicycles"
req3 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .apply(type: "'bicycle'")
                                                .group_by('@type', Redis::Commands::Search::Reducers.count.as('num_total'))

res3 = index.aggregate(req3)
puts "Total results: #{res3.size}"
puts "Results:"
res3.each do |row|
  puts "  Type: #{row['type']}, " \
       "Total: #{row['num_total']}"
end
puts
# STEP_END

# STEP_START agg4
# Example 4: GROUPBY with TOLIST reducer - List bicycles by condition
puts "Example 4: GROUPBY with TOLIST reducer - List bicycles by condition"
req4 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('__key')
                                                .group_by('@condition', Redis::Commands::Search::Reducers.tolist('__key').as('bicycles'))

res4 = index.aggregate(req4)
puts "Total results: #{res4.size}"
puts "Results:"
res4.each do |row|
  puts "  Condition: #{row['condition']}"
  puts "  Bicycles: #{row['bicycles']}"
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

res5 = index.aggregate(req5)
puts "Total results: #{res5.size}"
puts "Results:"
res5.each do |row|
  puts "  Condition: #{row['condition']}"
  puts "    Count: #{row['count']}"
  puts "    Total Price: #{row['total_price']}"
  puts "    Avg Price: #{row['avg_price']}"
  puts "    Min Price: #{row['min_price']}"
  puts "    Max Price: #{row['max_price']}"
end
puts
# STEP_END

# STEP_START agg6
# Example 6: SORTBY - Sort results by price descending
puts "Example 6: SORTBY - Sort results by price descending"
req6 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('__key', 'price', 'brand')
                                                .sort_by(Redis::Commands::Search::Desc.new('@price'))

res6 = index.aggregate(req6)
puts "Total results: #{res6.size}"
puts "Results (top 5):"
res6.first(5).each do |row|
  puts "  Brand: #{row['brand']}, " \
       "Price: #{row['price']}"
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

res7 = index.aggregate(req7)
puts "Total results: #{res7.size}"
puts "Results (offset 2, limit 3):"
res7.each do |row|
  puts "  Brand: #{row['brand']}, " \
       "Price: #{row['price']}"
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

res8 = index.aggregate(req8)
puts "Total results: #{res8.size}"
puts "Results (conditions with avg price > 1000):"
res8.each do |row|
  puts "  Condition: #{row['condition']}, " \
       "Avg Price: #{row['avg_price']}"
end
puts
# STEP_END

# STEP_START agg9
# Example 9: Complex aggregation pipeline
puts "Example 9: Complex aggregation pipeline - Price analysis by condition"
req9 = Redis::Commands::Search::AggregateRequest.new('*')
                                                .load('price', 'brand')
                                                .apply(expensive: '@price >= 1000')
                                                .group_by(['@condition', '@expensive'],
                                                          Redis::Commands::Search::Reducers.count.as('count'),
                                                          Redis::Commands::Search::Reducers.avg('@price').as('avg_price'))
                                                .sort_by(Redis::Commands::Search::Desc.new('@count'))

res9 = index.aggregate(req9)
puts "Total results: #{res9.size}"
puts "Results:"
res9.each do |row|
  puts "  Condition: #{row['condition']}, " \
       "Expensive (price >= 1000): #{row['expensive']}, " \
       "Count: #{row['count']}, " \
       "Avg Price: #{row['avg_price']}"
end
puts
# STEP_END

puts "All aggregation examples completed successfully!"
