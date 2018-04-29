require 'rubygems'
require 'redis'

r = Redis.new


puts
p "add values in zset-key"
r.zadd("zset-key", [1, "a", 2, "b"])
r.zadd "zset-key", 1, "s1"


puts
p "get length of zset-key"
p r.zcard('zset-key')

puts
p "increment a key"
r.zincrby "zset-key", 1, "a"


puts
p "remove a key"
r.zrem("zset-key", "a")


puts
p "get score a key"
r.zscore('zset-key', 'b')

puts
p "get zrank a key"
r.zscore('zset-key', 'c')

puts
p "get all"
p r.zrange('zset-key', 0, -1)
