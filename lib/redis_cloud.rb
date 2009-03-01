require 'redis'
require 'hash_ring'
class RedisCloud
  attr_reader :ring
  def initialize(*servers)
    srvs = []
    servers.each do |s|
      server, port = s.split(':')
      srvs << Redis.new(:host => server, :port => port)
    end
    @ring = HashRing.new srvs, 3
  end
  
  def method_missing(sym, *args, &blk)
    if redis = @ring.get_node(args.first)
      redis.send sym, *args, &blk
    else
      super
    end
  end
  
  def keys(glob)
    keyz = []
    @ring.nodes.each do |red|
      keyz.concat red.keys(glob)
    end
    keyz
  end
  
  def save
    @ring.nodes.each do |red|
      red.save
    end
  end
  
  def bgsave
    @ring.nodes.each do |red|
      red.bgsave
    end
  end
  
  def quit
    @ring.nodes.each do |red|
      red.quit
    end
  end
  
end

if __FILE__ == $0

r = RedisCloud.new 'localhost:6379', 'localhost:6380', 'localhost:6381','localhost:6382'
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
  
  r.push_tail 'listor', 'foo1'
  r.push_tail 'listor', 'foo2'
  r.push_tail 'listor', 'foo3'
  r.push_tail 'listor', 'foo4'
  r.push_tail 'listor', 'foo5'
  
  p r.pop_tail 'listor'
  p r.pop_tail 'listor'
  p r.pop_tail 'listor'
  p r.pop_tail 'listor'
  p r.pop_tail 'listor'
  
  puts "key distribution:"
  
  r.ring.nodes.each do |red|
    p [red.port, red.keys("*")]
  end
  
  p r.keys('*')
end
