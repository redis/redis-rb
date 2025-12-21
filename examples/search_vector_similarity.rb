# !/usr/bin/env ruby
# frozen_string_literal: true

# Redis Vector Similarity Search Example
#
# This example demonstrates vector similarity search operations including:
# - Creating vector indexes with HNSW and FLAT algorithms
# - Adding vectors to Redis
# - KNN (K-Nearest Neighbors) search
# - Hybrid search (vector + filters)
# - Range queries with distance thresholds
# - Using both FT.SEARCH with KNN syntax and VectorSimilarityQuery
#
# Vectors (also called "Embeddings") represent an AI model's impression of
# unstructured data like text, images, audio, etc. Vector Similarity Search (VSS)
# is the process of finding vectors in the database that are similar to a query vector.
#
# Run this example with: ruby examples/search_vector_similarity.rb

require 'redis'
require 'json'

# STEP_START connect
redis = Redis.new(host: 'localhost', port: 6400)
# STEP_END

puts "=== Redis Vector Similarity Search Example ==="

# Clean up any existing data
puts "\n--- Cleanup ---"
begin
  redis.ft_dropindex('idx:vector_hnsw', delete_documents: true)
rescue Redis::CommandError
  # Index doesn't exist, continue
end

begin
  redis.ft_dropindex('idx:vector_flat', delete_documents: true)
rescue Redis::CommandError
  # Index doesn't exist, continue
end

# STEP_START create_hnsw_index
puts "\n--- Creating HNSW Vector Index ---"
# HNSW (Hierarchical Navigable Small World) is optimized for fast approximate search
schema_hnsw = Redis::Commands::Search::Schema.build do
  tag_field 'tag'
  text_field 'content'
  vector_field 'vector', 'HNSW', {
    'TYPE' => 'FLOAT32',
    'DIM' => 6,
    'DISTANCE_METRIC' => 'COSINE'
  }
end

definition_hnsw = Redis::Commands::Search::IndexDefinition.new(
  prefix: ['doc:hnsw:'],
  index_type: Redis::Commands::Search::IndexType::HASH
)

redis.create_index('idx:vector_hnsw', schema_hnsw, definition: definition_hnsw)
puts "Created HNSW index: idx:vector_hnsw"
# STEP_END

# STEP_START create_flat_index
puts "\n--- Creating FLAT Vector Index ---"
# FLAT provides exact (brute-force) search, useful for smaller datasets
schema_flat = Redis::Commands::Search::Schema.build do
  tag_field 'tag'
  text_field 'content'
  vector_field 'vector', 'FLAT', {
    'TYPE' => 'FLOAT32',
    'DIM' => 6,
    'DISTANCE_METRIC' => 'L2'
  }
end

definition_flat = Redis::Commands::Search::IndexDefinition.new(
  prefix: ['doc:flat:'],
  index_type: Redis::Commands::Search::IndexType::HASH
)

redis.create_index('idx:vector_flat', schema_flat, definition: definition_flat)
puts "Created FLAT index: idx:vector_flat"
# STEP_END

# STEP_START add_vectors
puts "\n--- Adding Vectors to Redis ---"
# Create sample vectors (in practice, these would come from an embedding model)
vectors = [
  { id: 'a', tag: 'foo', content: 'Vector A', vector: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6] },
  { id: 'b', tag: 'foo', content: 'Vector B', vector: [0.2, 0.3, 0.4, 0.5, 0.6, 0.7] },
  { id: 'c', tag: 'bar', content: 'Vector C', vector: [0.3, 0.4, 0.5, 0.6, 0.7, 0.8] },
  { id: 'd', tag: 'bar', content: 'Vector D', vector: [0.8, 0.7, 0.6, 0.5, 0.4, 0.3] }
]

# Add to HNSW index
vectors.each do |vec|
  key = "doc:hnsw:#{vec[:id]}"
  # Pack vector as binary FLOAT32 data
  vector_bytes = vec[:vector].pack('f*')
  redis.hset(key, 'tag', vec[:tag], 'content', vec[:content], 'vector', vector_bytes)
  puts "Added #{key} to HNSW index"
end

# Add to FLAT index
# rubocop:disable Style/CombinableLoops
vectors.each do |vec|
  key = "doc:flat:#{vec[:id]}"
  vector_bytes = vec[:vector].pack('f*')
  redis.hset(key, 'tag', vec[:tag], 'content', vec[:content], 'vector', vector_bytes)
  puts "Added #{key} to FLAT index"
end
# rubocop:enable Style/CombinableLoops

# Wait for indexing to complete
sleep 0.5
# STEP_END

# STEP_START knn_search
puts "\n--- KNN Search (K-Nearest Neighbors) ---"
# Find the 2 most similar vectors to our query vector
query_vector = [0.15, 0.25, 0.35, 0.45, 0.55, 0.65]
query_bytes = query_vector.pack('f*')

# Using FT.SEARCH with KNN syntax
result = redis.ft_search(
  'idx:vector_hnsw',
  '*=>[KNN 2 @vector $query_vector AS score]',
  sortby: ['score', 'ASC'],
  return: ['content', 'tag', 'score'],
  dialect: 2,
  params: { 'query_vector' => query_bytes }
)

puts "Found #{result[0]} results:"
i = 1
while i < result.length
  doc_id = result[i]
  fields = result[i + 1]
  puts "  #{doc_id}: #{fields.inspect}"
  i += 2
end
# STEP_END

# STEP_START hybrid_search
puts "\n--- Hybrid Search (Vector + Tag Filter) ---"
# Combine vector similarity with traditional filters
# Find vectors similar to query, but only with tag 'foo'
result = redis.ft_search(
  'idx:vector_hnsw',
  '(@tag:{foo})=>[KNN 2 @vector $query_vector AS score]',
  sortby: ['score', 'ASC'],
  return: ['content', 'tag', 'score'],
  dialect: 2,
  params: { 'query_vector' => query_bytes }
)

puts "Found #{result[0]} results with tag 'foo':"
i = 1
while i < result.length
  doc_id = result[i]
  fields = result[i + 1]
  puts "  #{doc_id}: #{fields.inspect}"
  i += 2
end
# STEP_END

# STEP_START range_query
puts "\n--- Range Query (Distance Threshold) ---"
# Find all vectors within a certain distance threshold
result = redis.ft_search(
  'idx:vector_flat',
  '@vector:[VECTOR_RANGE $radius $query_vector]=>{$YIELD_DISTANCE_AS: score}',
  sortby: ['score', 'ASC'],
  return: ['content', 'tag', 'score'],
  dialect: 2,
  params: {
    'query_vector' => query_bytes,
    'radius' => 0.5
  }
)

puts "Found #{result[0]} results within distance 0.5:"
i = 1
while i < result.length
  doc_id = result[i]
  fields = result[i + 1]
  puts "  #{doc_id}: #{fields.inspect}"
  i += 2
end
# STEP_END

# STEP_START query_object
puts "\n--- Using Query Object ---"
# Alternative approach using Query object for more complex queries
query = Redis::Commands::Search::Query.new('*=>[KNN 3 @vector $query_vector AS score]')
                                      .sort_by('score', 'ASC')
                                      .return_field('content')
                                      .return_field('tag')
                                      .return_field('score')
                                      .paging(0, 3)
                                      .dialect(2)

# Convert query to string for ft_search
query_string = query.to_redis_args[0]
result = redis.ft_search(
  'idx:vector_hnsw',
  query_string,
  sortby: ['score', 'ASC'],
  return: ['content', 'tag', 'score'],
  dialect: 2,
  params: { 'query_vector' => query_bytes }
)

puts "Found #{result[0]} results using Query object:"
i = 1
while i < result.length
  doc_id = result[i]
  fields = result[i + 1]
  puts "  #{doc_id}: #{fields.inspect}"
  i += 2
end
# STEP_END

# STEP_START flat_vs_hnsw
puts "\n--- Comparing FLAT vs HNSW ---"
# FLAT: Exact search (brute-force), slower but 100% accurate
flat_result = redis.ft_search(
  'idx:vector_flat',
  '*=>[KNN 2 @vector $query_vector AS score]',
  sortby: ['score', 'ASC'],
  return: ['content', 'score'],
  dialect: 2,
  params: { 'query_vector' => query_bytes }
)

puts "FLAT results (exact search):"
i = 1
while i < flat_result.length
  doc_id = flat_result[i]
  fields = flat_result[i + 1]
  puts "  #{doc_id}: score=#{fields[fields.index('score') + 1]}"
  i += 2
end

# HNSW: Approximate search, faster but may miss some results
hnsw_result = redis.ft_search(
  'idx:vector_hnsw',
  '*=>[KNN 2 @vector $query_vector AS score]',
  sortby: ['score', 'ASC'],
  return: ['content', 'score'],
  dialect: 2,
  params: { 'query_vector' => query_bytes }
)

puts "\nHNSW results (approximate search):"
i = 1
while i < hnsw_result.length
  doc_id = hnsw_result[i]
  fields = hnsw_result[i + 1]
  puts "  #{doc_id}: score=#{fields[fields.index('score') + 1]}"
  i += 2
end
# STEP_END

# STEP_START hybrid_with_numeric
puts "\n--- Hybrid Search with Multiple Filters ---"
# Add some documents with numeric fields for more complex filtering
redis.hset('doc:hnsw:e', 'tag', 'premium', 'content', 'Vector E', 'price', '100', 'vector',
           [0.1, 0.1, 0.1, 0.1, 0.1, 0.1].pack('f*'))
redis.hset('doc:hnsw:f', 'tag', 'premium', 'content', 'Vector F', 'price', '200', 'vector',
           [0.2, 0.2, 0.2, 0.2, 0.2, 0.2].pack('f*'))

# Add numeric field to schema (alter index)
begin
  redis.ft_alter('idx:vector_hnsw', 'SCHEMA', 'ADD', 'price', 'NUMERIC')
  sleep 0.5

  # Search with both tag and numeric filter
  result = redis.ft_search(
    'idx:vector_hnsw',
    '(@tag:{premium} @price:[100 150])=>[KNN 2 @vector $query_vector AS score]',
    sortby: ['score', 'ASC'],
    return: ['content', 'tag', 'price', 'score'],
    dialect: 2,
    params: { 'query_vector' => query_bytes }
  )

  puts "Found #{result[0]} premium results with price 100-150:"
  i = 1
  while i < result.length
    doc_id = result[i]
    fields = result[i + 1]
    puts "  #{doc_id}: #{fields.inspect}"
    i += 2
  end
rescue Redis::CommandError => e
  puts "Note: Numeric filter example skipped (#{e.message})"
end
# STEP_END

puts "\n=== Example Complete ==="
puts "\nKey Takeaways:"
puts "1. HNSW is faster for large datasets (approximate search)"
puts "2. FLAT is exact but slower (brute-force search)"
puts "3. Use COSINE for normalized vectors, L2 for absolute distances"
puts "4. Hybrid queries combine vector search with traditional filters"
puts "5. Range queries find all vectors within a distance threshold"
puts "6. Always use dialect 2 for vector search queries"
