require 'rubygems'
require 'redis'

puts "To play with this example use redis-cli from another terminal, like this:"
puts "  ./redis-cli publish a hello"
puts "Finally force the example to exit sending the 'exit' message with"
puts "  ./redis-cli publish b exit"
puts ""
r = Redis.new(:timeout => 0)
r.subscribe(:a,:b) {|msg|
    if msg[:type] == "subscribe"
        puts "Subscribed to #{msg[:class]} (#{msg[:data]} subscriptions)"
    elsif msg[:type] == "message"
        puts "Got data: #{msg.inspect}"
        if msg[:data] == "exit"
            r.unsubscribe
        end
    end
}
