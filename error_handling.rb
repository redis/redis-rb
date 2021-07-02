Error Handling
In general, if something goes wrong you'll get an exception. For example, if it can't connect to the server a Redis::CannotConnectError error will be raised.

begin
  redis.ping
rescue StandardError => e
  e.inspect
# => #<Redis::CannotConnectError: Timed out connecting to Redis on 10.0.1.1:6380>

  e.message
# => Timed out connecting to Redis on 10.0.1.1:6380
end
See lib/redis/errors.rb for information about what exceptions are possible.
