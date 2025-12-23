# frozen_string_literal: true

# EXAMPLE: vecset_tutorial
# This example demonstrates Redis Vector Set operations including:
# - VADD - Adding vectors to a vector set
# - VCARD and VDIM - Getting cardinality and dimensionality
# - VEMB - Retrieving vector embeddings
# - VSETATTR and VGETATTR - Setting and getting JSON attributes
# - VSIM - Vector similarity search with various options (WITHSCORES, WITHATTRIBS, COUNT, EF, FILTER, TRUTH, NOTHREAD)
# - VREM - Removing elements
# - Quantization options (NOQUANT, Q8, BIN)
# - REDUCE - Dimensionality reduction
# - Filtering with mathematical expressions

require 'redis'
require 'json'

# Connect to Redis on port 6400
redis = Redis.new(host: 'localhost', port: 6400)

# Clear any keys before using them
redis.del('points', 'quantSetQ8', 'quantSetNoQ', 'quantSetBin', 'setNotReduced', 'setReduced')

# STEP_START vadd
res1 = redis.vadd('points', [1.0, 1.0], 'pt:A')
puts res1  # => 1

res2 = redis.vadd('points', [-1.0, -1.0], 'pt:B')
puts res2  # => 1

res3 = redis.vadd('points', [-1.0, 1.0], 'pt:C')
puts res3  # => 1

res4 = redis.vadd('points', [1.0, -1.0], 'pt:D')
puts res4  # => 1

res5 = redis.vadd('points', [1.0, 0.0], 'pt:E')
puts res5  # => 1

res6 = redis.type('points')
puts res6  # => vectorset
# STEP_END

# STEP_START vcardvdim
res7 = redis.vcard('points')
puts res7  # => 5

res8 = redis.vdim('points')
puts res8  # => 2
# STEP_END

# STEP_START vemb
res9 = redis.vemb('points', 'pt:A')
puts res9.inspect # => [0.9999999..., 0.9999999...]

res10 = redis.vemb('points', 'pt:B')
puts res10.inspect  # => [-0.9999999..., -0.9999999...]

res11 = redis.vemb('points', 'pt:C')
puts res11.inspect  # => [-0.9999999..., 0.9999999...]

res12 = redis.vemb('points', 'pt:D')
puts res12.inspect  # => [0.9999999..., -0.9999999...]

res13 = redis.vemb('points', 'pt:E')
puts res13.inspect  # => [1.0, 0.0]
# STEP_END

# STEP_START attr
res14 = redis.vsetattr('points', 'pt:A', '{"name":"Point A","description":"First point added"}')
puts res14 # => 1

res15 = redis.vgetattr('points', 'pt:A')
puts res15.inspect
# => {"name"=>"Point A", "description"=>"First point added"}

res16 = redis.vsetattr('points', 'pt:A', '')
puts res16 # => 1

res17 = redis.vgetattr('points', 'pt:A')
puts res17.inspect # => nil
# STEP_END

# STEP_START vrem
res18 = redis.vadd('points', [0.0, 0.0], 'pt:F')
puts res18  # => 1

res19 = redis.vcard('points')
puts res19  # => 6

res20 = redis.vrem('points', 'pt:F')
puts res20  # => 1

res21 = redis.vcard('points')
puts res21  # => 5
# STEP_END

# STEP_START vsim_basic
res22 = redis.vsim('points', [0.9, 0.1])
puts res22.inspect
# => ["pt:E", "pt:A", "pt:D", "pt:C", "pt:B"]
# STEP_END

# STEP_START vsim_options
res23 = redis.vsim('points', 'pt:A', with_scores: true, count: 4)
puts res23.inspect
# => {"pt:A"=>1.0, "pt:E"≈0.85355, "pt:D"=>0.5, "pt:C"=>0.5}
# STEP_END

# STEP_START vsim_filter
res24 = redis.vsetattr('points', 'pt:A', '{"size":"large","price":18.99}')
puts res24  # => 1

res25 = redis.vsetattr('points', 'pt:B', '{"size":"large","price":35.99}')
puts res25  # => 1

res26 = redis.vsetattr('points', 'pt:C', '{"size":"large","price":25.99}')
puts res26  # => 1

res27 = redis.vsetattr('points', 'pt:D', '{"size":"small","price":21.00}')
puts res27  # => 1

res28 = redis.vsetattr('points', 'pt:E', '{"size":"small","price":17.75}')
puts res28  # => 1

res29 = redis.vsim('points', 'pt:A', filter: '.size == "large"')
puts res29.inspect  # => ["pt:A", "pt:C", "pt:B"]

res30 = redis.vsim('points', 'pt:A', filter: '.size == "large" && .price > 20.00')
puts res30.inspect  # => ["pt:C", "pt:B"]
# STEP_END

# STEP_START add_quant
res31 = redis.vadd('quantSetQ8', [1.262185, 1.958231], 'quantElement', quantization: 'q8')
puts res31 # => 1

res32 = redis.vemb('quantSetQ8', 'quantElement')
puts "Q8: #{res32.inspect}"
# => Q8: [~1.264, ~1.958]

res33 = redis.vadd('quantSetNoQ', [1.262185, 1.958231], 'quantElement', quantization: 'noquant')
puts res33 # => 1

res34 = redis.vemb('quantSetNoQ', 'quantElement')
puts "NOQUANT: #{res34.inspect}"
# => NOQUANT: [~1.262185, ~1.958231]

res35 = redis.vadd('quantSetBin', [1.262185, 1.958231], 'quantElement', quantization: 'bin')
puts res35 # => 1

res36 = redis.vemb('quantSetBin', 'quantElement')
puts "BIN: #{res36.inspect}"
# => BIN: [1.0, 1.0]
# STEP_END

# STEP_START add_reduce
values = Array.new(300) { |i| i / 299.0 }

res37 = redis.vadd('setNotReduced', values, 'element')
puts res37  # => 1

res38 = redis.vdim('setNotReduced')
puts res38  # => 300

res39 = redis.vadd('setReduced', values, 'element', reduce_dim: 100)
puts res39  # => 1

res40 = redis.vdim('setReduced')
puts res40  # => 100
# STEP_END

redis.close
puts "\nVector set tutorial completed successfully!"
