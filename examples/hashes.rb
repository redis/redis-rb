require 'rubygems'
require 'redis'

r = Redis.new

puts
p "create hash by using hmset"
r.hmset("hash-key", *{'foo1' => 'bar1', 'foo2' => 'bar2', 'foo3' => 'bar3'})

p r.hgetall "hash-key"

puts
p "create hash by using mapped_hmset"
r.mapped_hmset("hash-mapped-hmset", 'foo1' => 'bar1', 'foo2' => 'bar2', 'foo3' => 'bar3')

p r.hgetall "hash-mapped-hmset"

p "get number of key-value pairs in hash"
p r.hlen "hash-key"


puts
p "delete a key"
r.hdel('hash-key', ['foo1', 'foo2'])


puts
p "delete a key"
r.hdel('hash-key', 'foo1')

puts
p "check existence of a key"
p r.hexists('hash-key', 'foo1')

puts
p "get all keys"
p r.hkeys('hash-key')


puts
p "get all values"
p r.hvals('hash-key')

puts
p "increment a key of a hash by a value"
r.hincrby('hash-key', 'incr-key', 2)

p r.hget('hash-key', 'incr-key')
