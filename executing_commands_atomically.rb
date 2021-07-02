Executing commands atomically
You can use MULTI/EXEC to run a number of commands in an atomic fashion. This is similar to executing a pipeline, but the commands are preceded by a call to MULTI, and followed by a call to EXEC. Like the regular pipeline, the replies to the commands are returned by the #multi method.

redis.multi do
  redis.set "foo", "bar"
  redis.incr "baz"
end
# => ["OK", 1]
