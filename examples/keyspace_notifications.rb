# frozen_string_literal: true

require "redis"

puts <<~EOS
  This example enables keyspace notifications on the server and watches events.

  Play with it from another terminal, for example:

    $ redis-cli set user:42 hello
    $ redis-cli expire user:42 1
    $ redis-cli hset session:1 token abc      # Redis 8.8+: watch the subkeys
    $ redis-cli del user:42

  Stop with Ctrl-C.

EOS

redis = Redis.new

# Server-side switch (usually done by your ops team in redis.conf instead):
# K = keyspace channels, E = keyevent channels, A = all data types,
# S/T/I/V = Redis 8.8 subkey channel families (need the type flag too, covered by A).
redis.config(:set, "notify-keyspace-events", "KEASTIV")

# --- Layer 1: builders + parser with the plain pub/sub DSL --------------------
# pattern = Redis::KeyspaceNotifications::Channels.keyspace("user:*", db: 0)
# redis.psubscribe(pattern) do |on|
#   on.pmessage do |matched, channel, payload|
#     n = Redis::KeyspaceNotifications::Parser.parse(channel, payload, pattern: matched)
#     puts "#{n.event} on #{n.key}" if n
#   end
# end

# --- Layer 2: the manager ------------------------------------------------------
manager = redis.keyspace_notifications(error_handler: ->(error) { warn "error: #{error.message}" })

manager.subscribe_keyspace("user:*") do |n|
  puts "[keyspace]  #{n.event.ljust(10)} key=#{n.key} (db #{n.db})"
end

manager.subscribe_keyevent("expired") do |n|
  puts "[keyevent]  expired    key=#{n.key}"
end

begin
  manager.subscribe_subkeyspace("session:*") do |n|
    puts "[subkeys]   #{n.event.ljust(10)} key=#{n.key} subkeys=#{n.subkeys.inspect}"
  end
rescue Redis::SubscriptionError
  puts "(subkey notifications need Redis 8.8+ — skipping that subscription)"
end

manager.on_reconnect do
  # Fire-and-forget: anything published while we were disconnected is gone.
  puts "reconnected — reconcile any state derived from notifications here"
end

puts "Listening for notifications... (Ctrl-C to stop)"
begin
  sleep
rescue Interrupt
  # Ctrl-C lands here as an Interrupt on the main thread. Don't close the manager
  # from a trap(:INT) handler instead — Ruby forbids acquiring locks in trap context.
  manager.close
  puts "bye"
end
