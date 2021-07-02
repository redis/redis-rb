Pipelining
When multiple commands are executed sequentially, but are not dependent, the calls can be pipelined. This means that the client doesn't wait for reply of the first command before sending the next command. The advantage is that multiple commands are sent at once, resulting in faster overall execution.

The client can be instructed to pipeline commands by using the #pipelined method. After the block is executed, the client sends all commands to Redis and gathers their replies. These replies are returned by the #pipelined method.

redis.pipelined do
  redis.set "foo", "bar"
  redis.incr "baz"
end
# => ["OK", 1]
