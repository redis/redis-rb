# !/usr/bin/env ruby
# frozen_string_literal: true

# Redis Query Engine - Hybrid Search (FT.HYBRID)
#
# Hybrid search fuses a lexical SEARCH leg (full-text / tag / numeric) with a vector
# similarity VSIM leg, then combines the two ranked lists. This example uses the high-level
# Index API (Index#hybrid_search) and the hybrid builder objects:
#
#   - HybridSearchQuery       the lexical leg ("SEARCH <query>")
#   - HybridVsimQuery         the vector leg ("VSIM @field $param")
#   - HybridQuery             pairs the two legs
#   - CombineResultsMethod    the fusion strategy (RRF or LINEAR)
#   - HybridPostProcessingConfig  an optional post-fusion pipeline (LOAD/APPLY/SORTBY/LIMIT/...)
#
# ft_hybrid_search / Index#hybrid_search return a Search::HybridResult: Enumerable over result
# rows (each a hash including the synthetic "__key" and "__score"), plus #total, #warnings and
# #execution_time.
#
# Requires Redis >= 8.4 (FT.HYBRID). Run with: ruby examples/search/search_hybrid.rb

require 'redis'

redis = Redis.new(host: 'localhost', port: 6379)

S = Redis::Commands::Search

# Clean up any existing index
begin
  redis.ft_dropindex('idx:products', delete_documents: true)
rescue Redis::CommandError
  # Index doesn't exist, continue
end

# STEP_START create_index
# A text field for the lexical leg, a tag/numeric for filtering, and a FLOAT32 vector field
# (dim 4, L2 distance) for the similarity leg.
schema = S::Schema.build do
  text_field :description
  tag_field :color
  numeric_field :price
  vector_field :embedding, 'FLAT', type: 'FLOAT32', dim: 4, distance_metric: 'L2'
end

index = redis.create_index('idx:products', schema,
                           definition: S::IndexDefinition.new(prefix: ['product:']))
# STEP_END

# STEP_START add_documents
# Vectors are packed as little-endian FLOAT32 binary blobs.
products = [
  { color: 'red',   description: 'red running shoes',    price: 80, embedding: [1.0, 2.0, 7.0, 8.0] },
  { color: 'green', description: 'green trail shoes',     price: 95,  embedding: [1.0, 4.0, 7.0, 8.0] },
  { color: 'red',   description: 'red summer dress',      price: 60,  embedding: [1.0, 2.0, 6.0, 5.0] },
  { color: 'blue',  description: 'blue denim jacket',     price: 120, embedding: [2.0, 3.0, 6.0, 5.0] },
  { color: 'black', description: 'black leather boots',   price: 150, embedding: [5.0, 6.0, 7.0, 8.0] }
]
products.each_with_index do |product, i|
  redis.hset("product:#{i}",
             'color', product[:color],
             'description', product[:description],
             'price', product[:price],
             'embedding', product[:embedding].pack('f*'))
end

# The vector we search "near" (reused across the examples below).
query_vector = [1.0, 2.0, 7.0, 6.0].pack('f*')
sleep 0.3 # let indexing settle
# STEP_END

# STEP_START basic
# Basic hybrid query: lexical match on "@color:{red}" fused with vector similarity. The reply
# is a HybridResult; each row carries "__key" (the document id) and "__score" (the fused score).
puts '1. Basic hybrid search (lexical @color:{red} + vector similarity)'
query = S::HybridQuery.new(
  S::HybridSearchQuery.new('@color:{red}'),
  S::HybridVsimQuery.new(vector_field_name: '@embedding', vector_data: '$vec')
)
result = index.hybrid_search(query: query, params_substitution: { 'vec' => query_vector })
puts "   total: #{result.total}, returned: #{result.size}"
result.first(3).each { |row| puts "   #{row['__key']} (score #{row['__score']})" }
puts

# STEP_END

# STEP_START combine_linear
# Control the fusion with a LINEAR combination (weights for the two legs), and trim with a
# post-processing LIMIT.
puts '2. LINEAR combination (alpha/beta) + LIMIT'
result = index.hybrid_search(
  query: query,
  combine_method: S::CombineResultsMethod.linear(alpha: 0.7, beta: 0.3),
  post_processing: S::HybridPostProcessingConfig.new.limit(0, 3),
  params_substitution: { 'vec' => query_vector }
)
result.each { |row| puts "   #{row['__key']} (score #{row['__score']})" }
puts

# STEP_END

# STEP_START combine_rrf
# Or fuse with Reciprocal Rank Fusion (RRF).
puts '3. RRF combination'
result = index.hybrid_search(
  query: query,
  combine_method: S::CombineResultsMethod.rrf(window: 20, constant: 60),
  params_substitution: { 'vec' => query_vector }
)
puts "   total: #{result.total}"
puts

# STEP_END

# STEP_START vsim_knn
# Restrict the vector leg to the K nearest neighbours. A lexical leg that matches nothing
# isolates the pure-KNN behaviour.
puts '4. Vector KNN (K=3), no lexical matches'
vsim = S::HybridVsimQuery.new(vector_field_name: '@embedding', vector_data: '$vec')
vsim.vsim_method_params(S::VectorSearchMethods::KNN, K: 3)
knn_query = S::HybridQuery.new(S::HybridSearchQuery.new('@color:{none}'), vsim)
result = index.hybrid_search(query: knn_query, params_substitution: { 'vec' => query_vector })
result.each { |row| puts "   #{row['__key']} (score #{row['__score']})" }
puts

# STEP_END

# STEP_START post_processing
# Post-fusion pipeline: LOAD source fields, SORTBY price ascending, LIMIT the page.
puts '5. Post-processing: load fields, sort by price'
post = S::HybridPostProcessingConfig.new
                                    .load('@__key', '@color', '@price', '@description')
                                    .sort_by(S::SortbyField.new('@price', asc: true))
                                    .limit(0, 5)
result = index.hybrid_search(query: query, post_processing: post,
                             params_substitution: { 'vec' => query_vector })
result.each do |row|
  puts "   #{row['__key']}: #{row['description']} - $#{row['price']} (#{row['color']})"
end
puts

# STEP_END

# STEP_START yield_score
# Expose each leg's individual score under an alias, alongside the fused "__score".
puts '6. Yield per-leg scores under aliases'
search_leg = S::HybridSearchQuery.new('shoes').yield_score_as('text_score')
vsim_leg = S::HybridVsimQuery.new(vector_field_name: '@embedding', vector_data: '$vec')
                             .yield_score_as('vec_score')
scored = S::HybridQuery.new(search_leg, vsim_leg)
post = S::HybridPostProcessingConfig.new.load('@__key', '@text_score', '@vec_score')
result = index.hybrid_search(query: scored, post_processing: post,
                             params_substitution: { 'vec' => query_vector })
result.each do |row|
  puts "   #{row['__key']}: text=#{row['text_score'] || '-'} vec=#{row['vec_score'] || '-'}"
end

# STEP_END

puts "\n=== Hybrid Search Complete ==="
