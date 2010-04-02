# redis-rb

A Ruby client library for the [Redis](http://code.google.com/p/redis) key-value storage system.

## Information about Redis

Redis is a key-value store with some interesting features:

1. It's fast.
2. Keys are strings but values are typed. Currently Redis supports strings, lists, sets, sorted sets and hashes. [Atomic operations](http://code.google.com/p/redis/wiki/CommandReference) can be done on all of these types.

See [the Redis homepage](http://code.google.com/p/redis/wiki/README) for more information.

## Usage

For all types redis-rb needs redis-server running to connect to.

### Simple Key Value Strings can be used like a large Ruby Hash (Similar to Memcached, Tokyo Cabinet)
	
	require 'redis'
	r = Redis.new
	r['key_one'] = "value_one"
	r['key_two'] = "value_two"
	
	r['key_one]  # => "value_one"

### Redis only stores strings. To store Objects, Array or Hashes, you must [Marshal](http://ruby-doc.org/core/classes/Marshal.html)
	
	require 'redis'
	r = Redis.new
	
	example_hash_to_store = {:name => "Alex", :age => 21, :password => "letmein", :cool => false}
	
	r['key_one'] = Marshal.dump(example_hash_to_store)
	
	hash_returned_from_redis = Marshal.load(r['key_one'])
	
### Alternatively you can use the [Redis Commands](http://code.google.com/p/redis/wiki/CommandReference)
	
	require 'redis'
	r = Redis.new
	r.set 'key_one', 'value_one'
	r.get 'key_one' # => 'value_one'
	
	# Using Redis list objects
	# Push an object to the head of the list. Creates the list if it doesn't allready exsist.
	
	blog_hash = {:title => "Redis Rules!", :body => "Ok so, like why, well like, RDBMS is like....", :created_at => Time.now.to_i}
	r.lpush 'all_blogs', Marshal.dump(blog_hash)
	
	# Get a range of strings from the all_blogs list. Similar to offset and limit in SQL (-1, means the last one)
	
	r.lrange 'all_blogs', 0, -1

### Multiple commands at once!

	require 'redis'
	r = Redis.new
	r.multi do
	  r.set 'foo', 'bar'
	  r.incr 'baz'
	end

## Contributing

See the build on [RunCodeRun](http://runcoderun.com/rsanheim/redis-rb).

If you would like to submit patches, you'll need Redis in your development environment:

		rake redis:install

## Examples

Check the `examples/` directory. You'll need to have an instance of `redis-server` running before running the examples.