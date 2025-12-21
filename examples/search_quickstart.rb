#!/usr/bin/env ruby
# frozen_string_literal: true

# Redis Search Quickstart Example
#
# This example demonstrates basic Redis Search operations including:
# - Creating a search index on JSON documents
# - Adding documents with various field types (text, numeric, tag)
# - Performing different types of searches (simple, numeric filter, tag filter, text search)
# - Using fuzzy search, prefix search, and pagination
# - Counting and limiting results
#
# Run this example with: ruby examples/search_quickstart.rb

require 'redis'
require 'json'
require_relative '../lib/redis/commands/json'
require_relative '../lib/redis/commands/search'

# STEP_START connect
redis = Redis.new(host: 'localhost', port: 6400)
redis.extend(Redis::Commands::JSON)
redis.extend(Redis::Commands::Search)
# STEP_END

# Clean up any existing index
begin
  redis.ft_dropindex('idx:bicycle', delete_documents: true)
rescue Redis::CommandError
  # Index doesn't exist, continue
end

# STEP_START create_index
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
# STEP_END

# Bicycle data
bicycles = [
  {
    brand: 'Velorim',
    model: 'Jigger',
    price: 270,
    condition: 'new',
    description: 'Small and powerful, the Jigger is the best ride for the smallest of tikes! ' \
                 'This is the tiniest kids\' pedal bike on the market available without a coaster brake, ' \
                 'the Jigger is the vehicle of choice for the rare tenacious little rider raring to go.'
  },
  {
    brand: 'Bicyk',
    model: 'Hillcraft',
    price: 1200,
    condition: 'used',
    description: 'Kids want to ride with as little weight as possible. Especially on an incline! ' \
                 'They may be at the age when a 27.5 inch wheel bike is just too clumsy coming off a 24 inch bike. ' \
                 'The Hillcraft 26 is just the solution they need!'
  },
  {
    brand: 'Nord',
    model: 'Chook air 5',
    price: 815,
    condition: 'used',
    description: 'The Chook Air 5 gives kids aged six years and older a durable and uberlight mountain bike ' \
                 'for their first experience on tracks and easy cruising through forests and fields. ' \
                 'The lower top tube makes it easy to mount and dismount in any situation, ' \
                 'giving your kids greater safety on the trails.'
  },
  {
    brand: 'Eva',
    model: 'Eva 291',
    price: 3400,
    condition: 'used',
    description: 'The sister company to Nord, Eva launched in 2005 as the first and only women-dedicated bicycle brand. ' \
                 'Designed by women for women, all Eva bikes are optimized for the feminine physique using analytics ' \
                 'from a body metrics database. If you like 29ers, try the Eva 291. It\'s a brand new bike for 2022. ' \
                 'This full-suspension, cross-country ride has been designed for velocity. ' \
                 'The 291 has 100mm of front and rear travel, a superlight aluminum frame and fast-rolling 29-inch wheels. Yippee!'
  },
  {
    brand: 'Noka Bikes',
    model: 'Kahuna',
    price: 3200,
    condition: 'used',
    description: 'Whether you want to try your hand at XC racing or are looking for a lively trail bike ' \
                 'that\'s just as inspiring on the climbs as it is over rougher ground, the Wilder is one heck of a bike ' \
                 'built specifically for short women. Both the frames and components have been tweaked to include ' \
                 'a women\'s saddle, different bars and unique colourway.'
  },
  {
    brand: 'Breakout',
    model: 'XBN 2.1 Alloy',
    price: 810,
    condition: 'new',
    description: 'The XBN 2.1 Alloy is our entry-level road bike – but that\'s not to say that it\'s a basic machine. ' \
                 'With an internal weld aluminium frame, a full carbon fork, and the slick-shifting Claris gears from Shimano\'s, ' \
                 'this is a bike which doesn\'t break the bank and delivers craved performance.'
  },
  {
    brand: 'ScramBikes',
    model: 'WattBike',
    price: 2300,
    condition: 'new',
    description: 'The WattBike is the best e-bike for people who still feel young at heart. ' \
                 'It has a Bafang 1000W mid-drive system and a 48V 17.5AH Samsung Lithium-Ion battery, ' \
                 'allowing you to ride for more than 60 miles on one charge. It\'s great for tackling hilly terrain ' \
                 'or if you just fancy a more leisurely ride. With three working modes, you can choose between ' \
                 'E-bike, assisted bicycle, and normal bike modes.'
  },
  {
    brand: 'Peaknetic',
    model: 'Secto',
    price: 430,
    condition: 'new',
    description: 'If you struggle with stiff fingers or a kinked neck or back after a few minutes on the road, ' \
                 'this lightweight, aluminum bike alleviates those issues and allows you to enjoy the ride. ' \
                 'From the ergonomic grips to the lumbar-supporting seat position, the Roll Low-Entry offers incredible comfort.'
  },
  {
    brand: 'nHill',
    model: 'Summit',
    price: 1200,
    condition: 'new',
    description: 'This budget mountain bike from nHill performs well both on bike paths and on the trail. ' \
                 'The fork with 100mm of travel absorbs rough terrain. Fat Kenda Booster tires give you grip in corners ' \
                 'and on wet trails. The Shimano Tourney drivetrain offered enough gears for finding a comfortable pace ' \
                 'to ride uphill, and the Tektro hydraulic disc brakes break smoothly.'
  },
  {
    brand: 'ThrillCycle',
    model: 'BikeShind',
    price: 815,
    condition: 'refurbished',
    description: 'An artsy, retro-inspired bicycle that\'s as functional as it is pretty: ' \
                 'The ThrillCycle steel frame offers a smooth ride. A 9-speed drivetrain has enough gears for coasting in the city, ' \
                 'but we wouldn\'t suggest taking it to the mountains. Fenders protect you from mud, ' \
                 'and a rear basket lets you transport groceries, flowers and books.'
  }
]

# STEP_START add_documents
bicycles.each_with_index do |bicycle, i|
  redis.json_set("bicycle:#{i}", '$', bicycle)
end
# STEP_END

# Wait for indexing to complete
sleep 0.5

# STEP_START wildcard_query
result1 = redis.ft_search('idx:bicycle', '*')
puts "Documents found: #{result1[0]}"
# Prints: Documents found: 10
# STEP_END

# STEP_START query_single_term
result2 = redis.ft_search('idx:bicycle', '@model:Jigger')
puts result2.inspect
# Prints: [1, "bicycle:0", ["$", "{\"brand\":\"Velorim\",\"model\":\"Jigger\",\"price\":270,...}"]]
# STEP_END

# STEP_START query_single_term_limit_fields
query3 = Redis::Commands::Search::Query.new('@model:Jigger').return(:price)
result3 = redis.ft_search('idx:bicycle', query3.to_redis_args[0], return: ['price'])
puts result3.inspect
# Prints: [1, "bicycle:0", ["price", "270"]]
# STEP_END

# STEP_START query_single_term_and_num_range
result4 = redis.ft_search('idx:bicycle', 'basic @price:[500 1000]')
puts result4.inspect
# Prints: [1, "bicycle:5", ["$", "{\"brand\":\"Breakout\",\"model\":\"XBN 2.1 Alloy\",\"price\":810,...}"]]
# STEP_END

# STEP_START query_exact_matching
result5 = redis.ft_search('idx:bicycle', '@brand:"Noka Bikes"')
puts result5.inspect
# Prints: [1, "bicycle:4", ["$", "{\"brand\":\"Noka Bikes\",\"model\":\"Kahuna\",\"price\":3200,...}"]]
# STEP_END

# STEP_START simple_aggregation
agg_result = redis.ft_aggregate('idx:bicycle', '*',
                                'GROUPBY', 1, '@condition',
                                'REDUCE', 'COUNT', 0, 'AS', 'count')
agg_result[1..-1].each do |row|
  condition = row[1]
  count = row[3]
  puts "#{condition} - #{count}"
end
# Prints:
# refurbished - 1
# used - 5
# new - 4
# STEP_END

puts "\n=== Additional Search Examples ==="

# Simple search for all documents
puts "\n1. Get all documents (wildcard search):"
result = redis.ft_search('idx:bicycle', '*')
puts "Total documents: #{result[0]}"

# Numeric filter
puts "\n2. Numeric filter - bikes priced between 500 and 1000:"
result = redis.ft_search('idx:bicycle', '@price:[500 1000]')
puts "Found #{result[0]} bike(s)"
result[1..-1].each_slice(2) do |id, _fields|
  puts "  - #{id}"
end

# Tag filter
puts "\n3. Tag filter - search for 'new' condition bikes:"
result = redis.ft_search('idx:bicycle', '@condition:{new}')
puts "Found #{result[0]} new bike(s)"

# Text search
puts "\n4. Text search - search for 'kids' in description:"
result = redis.ft_search('idx:bicycle', '@description:kids')
puts "Found #{result[0]} bike(s) for kids"

# Fuzzy search
puts "\n5. Fuzzy search - search for 'Noka' with typo tolerance:"
result = redis.ft_search('idx:bicycle', '%Noka%')
puts "Found #{result[0]} bike(s) matching fuzzy search"

# Prefix search
puts "\n6. Prefix search - models starting with 'Bike':"
result = redis.ft_search('idx:bicycle', '@model:Bike*')
puts "Found #{result[0]} bike(s) with model starting with 'Bike'"

# Limit results
puts "\n7. Limit results - get only 3 bikes:"
result = redis.ft_search('idx:bicycle', '*', limit: [0, 3])
puts "Returned #{(result.length - 1) / 2} bike(s) (limited to 3)"

# Count results
puts "\n8. Count results - count all bikes without returning documents:"
query = Redis::Commands::Search::Query.new('*').no_content
result = redis.ft_search('idx:bicycle', query.to_redis_args[0], no_content: true)
puts "Total count: #{result[0]} (no documents returned)"

# Pagination
puts "\n9. Pagination - get page 2 with 3 items per page:"
page = 2
page_size = 3
offset = (page - 1) * page_size
result = redis.ft_search('idx:bicycle', '*', limit: [offset, page_size])
puts "Page #{page}: #{(result.length - 1) / 2} bike(s)"
result[1..-1].each_slice(2) do |id, _fields|
  puts "  - #{id}"
end

puts "\n=== Search Quickstart Complete ==="
