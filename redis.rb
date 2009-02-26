require 'socket'
require 'timeout'

class RedisError < StandardError
end

class Redis
  OK = "+OK".freeze
  
  def initialize(opts={})
    @opts = {:host => 'localhost', :port => '6379'}.merge(opts)
  end
  
  def []=(key, val)
    write "SET #{key} #{val.size}\r\n#{val}\r\n"
    res = read_data
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end    
  end
  
  def [](key)
    write "GET #{key}\r\n"
    if read_data != "nil"
      read_data
    else
      nil
    end    
  end
  
  def key?(key)
    write "EXISTS #{key}\r\n"
    read_data.to_i == 0
  end
  
  def delete(key)
    write "DEL #{key}\r\n"
    if read_data == OK
      true
    else
      raise RedisError
    end
  end
  
  def keys(glob)
    write "KEYS #{glob}\r\n"
    res = read_data
    if res
      read_data.split(" ")
    end
  end
  
  private
  
  def close
    socket.close unless socket.closed?
  end
  
  def timeout_retry(time, retries, &block)
    timeout(time, &block)
  rescue TimeoutError
    retries -= 1
    retry unless retries < 0
  end
  
  def socket
    connect if (!@socket or @socket.closed?)
    @socket
  end
  
  def connect
    @socket = TCPSocket.new(@opts[:host], @opts[:port])
    @socket.sync = true
    @socket
  end
  
  def read(length)
    retries = 3
    res = socket.read(length)
  rescue => boom
    retries -= 1
    if retries > 0
      connect
      retry
    end
  end
  
  def write(data)
    retries = 3
    socket.write(data)
  rescue => boom
    retries -= 1
    if retries > 0
      connect
      retry
    end
  end
  
  def read_data
    buff = ""
    while (char = read(1))
      p char
      buff << char
      break if buff[-2..-1] == "\r\n"
    end
    res = buff[0..-3]
    res.size == 0 ? nil : res
  end
  
end

if __FILE__ == $0
  r = Redis.new
  p r.keys "*"
  r["buns"] = "hellow world!"
  p r["buns"]
  #
  r["kill"] = "hellow world!"
  p r["kill"]
  p r['nothinghere']
  r['nos'] = "another"
  p r.keys "h*"

end
