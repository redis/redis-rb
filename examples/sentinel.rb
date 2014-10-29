require 'redis'

Sentinels = [{:host => "127.0.0.1", :port => 26379},
             {:host => "127.0.0.1", :port => 26380}]
r = Redis.new(:url => "sentinel://mymaster", :sentinels => Sentinels, :role => :master)

# Set keys into a loop.
#
# The example traps errors so that you can actually try to failover while
# running the script to see redis-rb reconfiguring.
(0..1000000).each{|i|
    begin
        r.set(i,i)
        puts i
    rescue
        puts "ERROR #{i}"
    end
    sleep(0.01)
}
