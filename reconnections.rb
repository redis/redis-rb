Reconnections
The client allows you to configure how many reconnect_attempts it should complete before declaring a connection as failed. Furthermore, you may want to control the maximum duration between reconnection attempts with reconnect_delay and reconnect_delay_max.

Redis.new(
  :reconnect_attempts => 10,
  :reconnect_delay => 1.5,
  :reconnect_delay_max => 10.0,
)
The delay values are specified in seconds. With the above configuration, the client would attempt 10 reconnections, exponentially increasing the duration between each attempt but it never waits longer than reconnect_delay_max.

This is the retry algorithm:

attempt_wait_time = [(reconnect_delay * 2**(attempt-1)), reconnect_delay_max
