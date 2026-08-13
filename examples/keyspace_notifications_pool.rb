# frozen_string_literal: true

# Using keyspace notifications together with the connection_pool gem.
#
# Strategy: ONE manager per process, no matter how many pooled connections or
# threads operate on the keyspace.
#
# - Pub/sub is a broadcast, not a work queue: every subscriber receives every
#   matching event. A manager per pooled connection would deliver (and handle)
#   each event N times — it would not share the load.
# - The manager is not a pooled resource. It duplicates the client's options
#   into a connection it owns exclusively (a subscribed connection cannot serve
#   regular commands), so create it once and let it live for the process' lifetime.
# - Handlers run on the manager's listener thread: keep them fast. To run Redis
#   commands from a handler, check a connection out of the pool briefly — never
#   use the manager's own connection — or hand the work to your own job queue.
# - After fork (Puma / Sidekiq / Spring workers): threads don't survive fork, so
#   create the manager in an after-fork hook, one per worker process.

require "redis"
begin
  require "connection_pool"
rescue LoadError
  abort "This example needs the connection_pool gem: gem install connection_pool"
end

POOL = ConnectionPool.new(size: 5, timeout: 3) { Redis.new }

# Server-side switch (usually done by your ops team in redis.conf instead).
POOL.with { |redis| redis.config(:set, "notify-keyspace-events", "KEA") }

# One manager for the whole process. Creating it inside a checkout is safe: it
# duplicates the checked-out client's *options* into its own private connection,
# so nothing of the pooled client is retained after the block returns.
manager = POOL.with(&:keyspace_notifications)

events = Queue.new
manager.subscribe_keyspace("counter:*") do |notification|
  # Redis work from a handler goes through the pool. Keep it brief: this runs on
  # the manager's listener thread and delays subsequent notifications.
  value = POOL.with { |redis| redis.get(notification.key) }
  events << "#{notification.event.ljust(7)} #{notification.key} (now #{value})"
end

# Any number of concurrent threads can write through the pool; the single
# subscription sees each event exactly once.
writers = Array.new(4) do |i|
  Thread.new do
    5.times { POOL.with { |redis| redis.incr("counter:#{i}") } }
  end
end
writers.each(&:join)

20.times do
  event = events.pop(timeout: 5)
  abort "timed out waiting for a notification" if event.nil?
  puts event
end

manager.close
POOL.with do |redis|
  redis.config(:set, "notify-keyspace-events", "")
  redis.del(*Array.new(4) { |i| "counter:#{i}" })
end
POOL.shutdown(&:close)
puts "done: 20 events, one subscription, #{writers.size} concurrent writers"
