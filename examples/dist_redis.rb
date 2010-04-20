require 'rubygems'
require 'redis'
require 'redis/dist_redis'

r = DistRedis.new :hosts => %w[localhost:6379 localhost:6380 localhost:6381 localhost:6382]
r['urmom'] = 'urmom'
r['urdad'] = 'urdad'
r['urmom1'] = 'urmom1'
r['urdad1'] = 'urdad1'
r['urmom2'] = 'urmom2'
r['urdad2'] = 'urdad2'
r['urmom3'] = 'urmom3'
r['urdad3'] = 'urdad3'
p r['urmom']
p r['urdad']
p r['urmom1']
p r['urdad1']
p r['urmom2']
p r['urdad2']
p r['urmom3']
p r['urdad3']

r.rpush 'listor', 'foo1'
r.rpush 'listor', 'foo2'
r.rpush 'listor', 'foo3'
r.rpush 'listor', 'foo4'
r.rpush 'listor', 'foo5'

p r.rpop('listor')
p r.rpop('listor')
p r.rpop('listor')
p r.rpop('listor')
p r.rpop('listor')

puts "key distribution:"

r.ring.nodes.each do |red|
  p [red.server, red.keys("*")]
end
r.delete_cloud!
p r.keys('*')
