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
redis = Redis.new(host: 'localhost', port: 6379)
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
  vector_field 'vector', 'HNSW', type: 'FLOAT32', dim: 6, distance_metric: 'COSINE'
end

definition_hnsw = Redis::Commands::Search::IndexDefinition.new(
  prefix: ['doc:hnsw:'],
  index_type: Redis::Commands::Search::IndexType::HASH
)

index_hnsw = redis.create_index('idx:vector_hnsw', schema_hnsw, definition: definition_hnsw)
puts "Created HNSW index: idx:vector_hnsw"
# STEP_END

# STEP_START create_flat_index
puts "\n--- Creating FLAT Vector Index ---"
# FLAT provides exact (brute-force) search, useful for smaller datasets
schema_flat = Redis::Commands::Search::Schema.build do
  tag_field 'tag'
  text_field 'content'
  vector_field 'vector', 'FLAT', type: 'FLOAT32', dim: 6, distance_metric: 'L2'
end

definition_flat = Redis::Commands::Search::IndexDefinition.new(
  prefix: ['doc:flat:'],
  index_type: Redis::Commands::Search::IndexType::HASH
)

index_flat = redis.create_index('idx:vector_flat', schema_flat, definition: definition_flat)
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
result = index_hnsw.search(
  '*=>[KNN 2 @vector $query_vector AS score]',
  sort_by: 'score',
  return_fields: ['content', 'tag', 'score'],
  params: { 'query_vector' => query_bytes }
)

puts "Found #{result.total} results:"
result.each do |doc|
  puts "  #{doc.id}: #{doc.attributes}"
end
# STEP_END

# STEP_START hybrid_search
puts "\n--- Hybrid Search (Vector + Tag Filter) ---"
# Combine vector similarity with traditional filters
# Find vectors similar to query, but only with tag 'foo'
result = index_hnsw.search(
  '(@tag:{foo})=>[KNN 2 @vector $query_vector AS score]',
  sort_by: 'score',
  return_fields: ['content', 'tag', 'score'],
  params: { 'query_vector' => query_bytes }
)

puts "Found #{result.total} results with tag 'foo':"
result.each do |doc|
  puts "  #{doc.id}: #{doc.attributes}"
end
# STEP_END

# STEP_START range_query
puts "\n--- Range Query (Distance Threshold) ---"
# Find all vectors within a certain distance threshold
result = index_flat.search(
  '@vector:[VECTOR_RANGE $radius $query_vector]=>{$YIELD_DISTANCE_AS: score}',
  sort_by: 'score',
  return_fields: ['content', 'tag', 'score'],
  params: {
    'query_vector' => query_bytes,
    'radius' => 0.5
  }
)

puts "Found #{result.total} results within distance 0.5:"
result.each do |doc|
  puts "  #{doc.id}: #{doc.attributes}"
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

# Pass the Query object directly to the index
result = index_hnsw.search(
  query,
  params: { 'query_vector' => query_bytes }
)

puts "Found #{result.total} results using Query object:"
result.each do |doc|
  puts "  #{doc.id}: #{doc.attributes}"
end
# STEP_END

# STEP_START flat_vs_hnsw
puts "\n--- Comparing FLAT vs HNSW ---"
# FLAT: Exact search (brute-force), slower but 100% accurate
flat_result = index_flat.search(
  '*=>[KNN 2 @vector $query_vector AS score]',
  sort_by: 'score',
  return_fields: ['content', 'score'],
  params: { 'query_vector' => query_bytes }
)

puts "FLAT results (exact search):"
flat_result.each do |doc|
  puts "  #{doc.id}: score=#{doc['score']}"
end

# HNSW: Approximate search, faster but may miss some results
hnsw_result = index_hnsw.search(
  '*=>[KNN 2 @vector $query_vector AS score]',
  sort_by: 'score',
  return_fields: ['content', 'score'],
  params: { 'query_vector' => query_bytes }
)

puts "\nHNSW results (approximate search):"
hnsw_result.each do |doc|
  puts "  #{doc.id}: score=#{doc['score']}"
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
  index_hnsw.alter(Redis::Commands::Search::NumericField.new('price'))
  sleep 0.5

  # Search with both tag and numeric filter
  result = index_hnsw.search(
    '(@tag:{premium} @price:[100 150])=>[KNN 2 @vector $query_vector AS score]',
    sort_by: 'score',
    return_fields: ['content', 'tag', 'price', 'score'],
    params: { 'query_vector' => query_bytes }
  )

  puts "Found #{result.total} premium results with price 100-150:"
  result.each do |doc|
    puts "  #{doc.id}: #{doc.attributes}"
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
puts "6. DIALECT 2 is the default; vector search relies on it"
