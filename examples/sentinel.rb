require 'redis'

at_exit do
  begin
    Process.kill(:INT, $redises)
  rescue Errno::ESRCH
  end

  Process.waitall
end

$redises = spawn("examples/sentinel/start")

Sentinels = [{:host => "127.0.0.1", :port => 26379},
             {:host => "127.0.0.1", :port => 26380}]
r = Redis.new(:url => "redis://master1", :sentinels => Sentinels, :role => :master)

# Set keys into a loop.
#
# The example traps errors so that you can actually try to failover while
# running the script to see redis-rb reconfiguring.
(0..1000000).each{|i|
    begin
        r.set(i,i)
        $stdout.write("SET (#{i} times)\n") if i % 100 == 0
    rescue => e
        $stdout.write("E")
    end
    sleep(0.01)
}
