require 'socket'

require File.join(File.dirname(__FILE__), '../lib/server')
require File.join(File.dirname(__FILE__), '../lib/better_timeout')

require 'pp'
class Redis
  
end
class RedisError < StandardError
end
def read_proto(s)
  with_socket(s) do |as|
buff = ""
while buff[-2..-1] != "\r\n"
  begin
  buff << as.read(1)
  rescue
    raise RedisError
  end
end

buff[0..-3]
end

end
r = Redis.new

s = Server.new(r, 'localhost', '6379')

def with_socket(server, &block)
  begin
    block.call(server.socket)
  #Timeout or server down
  rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED => e
    #puts "Client (#{server.inspect}) disconnected from server: #{e.inspect}\n"
    server.close
    retry
  #Server down
  rescue NoMethodError => e
    #puts "Client (#{server.inspect}) tryin server that is down: #{e.inspect}\n"
    puts "Dying!"
    exit
  
  end

end

loop do
  with_socket(s) do |as|
    begin
    as.write("INFO \r\n")
    res = read_proto(s)
    if res.index("-") == 0
      err = as.read(res.to_i.abs+2)
      raise RedisError, err.chomp
    elsif res != NIL
      val = as.read(res.to_i.abs+2)
      puts val.chomp
    else
      puts nil
    end
    puts "--------------------------------------"
    rescue RedisError
      puts "\nRetrying!\n\n"
      retry
    end
  end
  sleep 11
end