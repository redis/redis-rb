require 'rubygems'
require 'redis'

puts "To play with this example use redis-cli from another terminal, like this:"
puts "  ./redis-cli publish a hello"
puts "Finally force the example to exit sending the 'exit' message with"
puts "  ./redis-cli publish b exit"
puts ""

r = Redis.new(:timeout => 0)
r.subscribe(:a,:b) do |s|

  s.subscribe do |channel,msg|
    puts "Subscribed to #{channel} (#{msg} subscriptions)"
  end

  s.message do |channel,val|
    puts "Got data: #{val} on channel #{channel}"
    if val == "exit"
      r.unsubscribe
    end
  end

end

