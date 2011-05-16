# Run with
#
#   $ ruby -Ilib benchmarking/scripting.rb
#

require "benchmark"
require "redis"

r = Redis.new

shuffle_list = <<LUA
local type = redis('type',KEYS[1])
if type.ok ~= 'list' then return {err = "Key is not a list"} end
local len = redis('llen',KEYS[1])
for i=0,len-1 do
local r = (math.random(len))-1
local a = redis("lindex",KEYS[1],i)
local b = redis("lindex",KEYS[1],r)
redis("lset",KEYS[1],i,b)
redis("lset",KEYS[1],r,a)
end
return len
LUA


n = (ARGV.shift || 1000).to_i

Benchmark.bmbm do |x|
  
  r.del(:mylist)
  (0..10).each{|x| r.lpush(:mylist,x)}
  
  x.report("eval") do
    n.times do |i|
      r.eval(shuffle_list,1,:mylist)
    end
  end
  
  
  r.del(:mylist)
  (0..10).each{|x| r.lpush(:mylist,x)}
  
  x.report("evalsha") do
    n.times do |i|
      r.evalsha(shuffle_list,1,:mylist)
    end
  end
  
  
  r.del(:mylist)
  (0..10).each{|x| r.lpush(:mylist,x)}
  
  x.report("ruby") do
    n.times do
      len = r.llen(:mylist)    
      len.times do |i|
        ran = rand(len)
        a = r.lindex(:mylist, i)
        b = r.lindex(:mylist, ran)
        r.lset(:mylist, i, b)
        r.lset(:mylist, ran, a)
      end
    end
  end
end
