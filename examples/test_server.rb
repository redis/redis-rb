require 'socket'

require File.join(File.dirname(__FILE__), '../lib/server')
require 'pp'
class Redis
  
end
r = Redis.new

s = Server.new(r, 'localhost', '6379')

retried = false
closed = false
loop do

  begin
    puts s.inspect
    x = s.socket.write("INFO\r\n")
    puts "X is #{x}\n\n"
  #Timeout or server down
  rescue Errno::EPIPE, Errno::ECONNREFUSED => e
    puts "Client (#{s.inspect}) disconnected from server: #{e.inspect}\n"
    s.close
    retry
  #Server down
  rescue NoMethodError# => e
    #puts "Client (#{s.inspect}) tryin server that is down: #{e.inspect}\n"
    #puts "Dying!"
    exit
  
  end

  sleep 15

end