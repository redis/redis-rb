Futures
Replies to commands in a pipeline can be accessed via the futures they emit (since redis-rb 3.0). All calls inside a pipeline block return a Future object, which responds to the #value method. When the pipeline has successfully executed, all futures are assigned their respective replies and can be used.

redis.pipelined do
  @set = redis.set "foo", "bar"
  @incr = redis.incr "baz"
end

@set.value
# => "OK"

@incr.value
# => 1
