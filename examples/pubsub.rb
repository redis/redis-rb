require 'rubygems'
require 'redis'

puts "To play with this example use redis-cli from another terminal, like this:"
puts "  ./redis-cli publish a hello"
puts "Finally force the example to exit sending the 'exit' message with"
puts "  ./redis-cli publish b exit"
puts ""

@redis = Redis.new(:timeout => 0)

@redis.subscribe('one','two') do |on|
  on.subscribe {|klass| puts "listening to #{klass}" }
  on.message do |klass, msg| 
    puts "#{klass} received: #{msg}"
    if msg == 'exit'
      @redis.unsubscribe
    end
  end
  on.unsubscribe {|klass| puts "see ya, #{klass}" }
end




