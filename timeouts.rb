Timeouts
The client allows you to configure connect, read, and write timeouts. Passing a single timeout option will set all three values:

Redis.new(:timeout => 1)
But you can use specific values for each of them:

Redis.new(
  :connect_timeout => 0.2,
  :read_timeout    => 1.0,
  :write_timeout   => 0.5
)
All timeout values are specified in seconds.

When using pub/sub, you can subscribe to a channel using a timeout as well:

redis = Redis.new(reconnect_attempts: 0)
redis.subscribe_with_timeout(5, "news") do |on|
  on.message do |channel, message|
    # ...
  end
end
If no message is received after 5 seconds, the client will unsubscribe.
