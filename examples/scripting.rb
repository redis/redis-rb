require 'redis'

r = Redis.new
increx = <<LUA
if redis("exists",KEYS[1]) == 1
then
return redis("incr",KEYS[1])
else
return nil
end
LUA

r.del(:counter)
puts r.eval(increx,1,:counter)
puts r.exists(:counter)
r.set(:counter,10)
puts r.eval(increx,1,:counter)