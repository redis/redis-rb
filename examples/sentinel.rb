# frozen_string_literal: true

require 'redis'

# This example creates a master-slave setup with a sentinel, then connects to
# it and sends write commands in a loop.
#
# After 30 seconds, the master dies. You will be able to see how a new master
# is elected and things continue to work as if nothing happened.
#
# To run this example:
#
#   $ ruby -I./lib examples/sentinel.rb
#

at_exit do
  begin
    Process.kill(:INT, @redises)
  rescue Errno::ESRCH
  end

  Process.waitall
end

@redises = spawn("examples/sentinel/start")

SENTINELS = [{ host: "127.0.0.1", port: 26_379 },
             { host: "127.0.0.1", port: 26_380 }].freeze
r = Redis.new(url: "redis://master1", sentinels: SENTINELS, role: :master)

# Set keys into a loop.
#
# The example traps errors so that you can actually try to failover while
# running the script to see redis-rb reconfiguring.
(0..1_000_000).each do |i|
  begin
    r.set(i, i)
    $stdout.write("SET (#{i} times)\n") if i % 100 == 0
  rescue
    $stdout.write("E")
  end
  sleep(0.01)
end
