require 'rubygems'
require 'redis'

puts "To play with this example use redis-cli from another terminal, like this:"
puts "  ./redis-cli publish one hello"
puts "Finally force the example to exit sending the 'exit' message with"
puts "  ./redis-cli publish two exit"
puts ""

@redis = Redis.new(:timeout => 0)

@redis.subscribe('one','two') do |on|
  on.subscribe {|klass, num_subs| puts "Subscribed to #{klass} (#{num_subs} subscriptions)" }
  on.message do |klass, msg| 
    puts "#{klass} received: #{msg}"
    if msg == 'exit'
      @redis.unsubscribe
    end
  end
  on.unsubscribe {|klass, num_subs| puts "Unsubscribed to #{klass} (#{num_subs} subscriptions)" }
end




