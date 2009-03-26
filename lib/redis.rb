require 'socket'
require 'set'
require File.join(File.dirname(__FILE__),'server')


class RedisError < StandardError
end
class RedisRenameError < StandardError
end
class Redis
  ERR = "-".freeze
  OK = 'OK'.freeze
  SINGLE = '+'.freeze
  BULK   = '$'.freeze
  MULTI  = '*'.freeze
  INT    = ':'.freeze
  
  attr_reader :server
  
  
  def initialize(opts={})
    @opts = {:host => 'localhost', :port => '6379'}.merge(opts)
    $debug = @opts[:debug]
    @server = Server.new(@opts[:host], @opts[:port])
  end
  
  def to_s
    "#{host}:#{port}"
  end
  
  def port
    @opts[:port]
  end
  
  def host
    @opts[:host]
  end

  def ensure_retry(&block)
    begin
      block.call
    rescue RedisError
      retry
    end
  end
  
  def with_socket_management(server, &block)
    begin
      block.call(server.socket)
    #Timeout or server down
    rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED => e
      server.close
      puts "Client (#{server.inspect}) disconnected from server: #{e.inspect}\n" if $debug
      retry
    #Server down
    rescue NoMethodError => e
      puts "Client (#{server.inspect}) tryin server that is down: #{e.inspect}\n Dying!" if $debug
      exit
    end
  end

  def quit
    write "QUIT\r\n"
  end
  
  def select_db(index)
    ensure_retry do
      write "SELECT #{index}\r\n"
      get_response
    end
  end
  
  def flush_db
    ensure_retry do
      write "FLUSHDB\r\n"
      get_response == OK
    end
  end    

  def last_save
    ensure_retry do
      write "LASTSAVE\r\n"
      get_response.to_i
    end
  end
  
  def bgsave
    ensure_retry do
      write "BGSAVE\r\n"
      get_response == OK
    end
  end  
    
  def info
   info = {}
   info = ensure_retry do
     write("INFO\r\n")
     x = get_response
     x.each do |kv|
       k,v = kv.split(':', 2)
       k,v = k.chomp, v = v.chomp
       info[k.to_sym] = v
     end
     info
    end
  end
  
  
  def bulk_reply
    begin
      x = read.chomp
      puts "bulk_reply read value is #{x.inspect}" if $debug
      return x
    rescue => e
      puts "error in bulk_reply #{e}" if $debug
      nil
    end
  end
  
  def write(data)
    with_socket_management(@server) do |socket|
      puts "writing: #{data}" if $debug
      socket.write(data)
    end
  end
  
  def fetch(len)
    with_socket_management(@server) do |socket|
      len = [0, len.to_i].max
      res = socket.read(len + 2)
      res = res.chomp if res
      res
    end
  end
  
  def read(length = read_proto)
    with_socket_management(@server) do |socket|
      res = socket.read(length)
      puts "read is #{res.inspect}" if $debug
      res
    end
  end

  def keys(glob)
    ensure_retry do
      write "KEYS #{glob}\r\n"
      get_response.split(' ')
    end
  end

  def rename!(oldkey, newkey)
    ensure_retry do
      write "RENAME #{oldkey} #{newkey}\r\n"
      get_response
    end
  end  
  
  def rename(oldkey, newkey)
    ensure_retry do
      write "RENAMENX #{oldkey} #{newkey}\r\n"
      case get_response
      when -1
        raise RedisRenameError, "source key: #{oldkey} does not exist"
      when 0
        raise RedisRenameError, "target key: #{oldkey} already exists"
      when -3
        raise RedisRenameError, "source and destination keys are the same"
      when 1
        true
      end
    end
  end  
  
  def key?(key)
    ensure_retry do
      write "EXISTS #{key}\r\n"
      get_response == 1
    end
  end  
  
  def delete(key)
    ensure_retry do
      write "DEL #{key}\r\n"
      get_response == 1
    end
  end  
  
  def [](key)
    ensure_retry do
      get(key)
    end
  end

  def get(key)
    ensure_retry do
      write "GET #{key}\r\n"
      get_response
    end
  end
  
  def mget(*keys)
    ensure_retry do
      write "MGET #{keys.join(' ')}\r\n"
      get_response
    end
  end

  def incr(key, increment=nil)
    ensure_retry do
      if increment
        write "INCRBY #{key} #{increment}\r\n"
      else
        write "INCR #{key}\r\n"
      end    
      get_response
    end
  end

  def decr(key, decrement=nil)
    ensure_retry do
      if decrement
        write "DECRRBY #{key} #{decrement}\r\n"
      else
        write "DECR #{key}\r\n"
      end    
      get_response
    end
  end
  
  def randkey
    ensure_retry do
      write "RANDOMKEY\r\n"
      get_response
    end
  end

  def list_length(key)
    ensure_retry do
      write "LLEN #{key}\r\n"
      case i = get_response
      when -2
        raise RedisError, "key: #{key} does not hold a list value"
      else
        i
      end
    end
  end

  def type?(key)
    ensure_retry do
      write "TYPE #{key}\r\n"
      get_response
    end
  end
  
  def push_tail(key, string)
    ensure_retry do
      write "RPUSH #{key} #{string.to_s.size}\r\n#{string.to_s}\r\n"
      get_response
    end
  end      

  def push_head(key, string)
    ensure_retry do
      write "LPUSH #{key} #{string.to_s.size}\r\n#{string.to_s}\r\n"
      get_response
    end
  end
  
  def pop_head(key)
    ensure_retry do
      write "LPOP #{key}\r\n"
      get_response
    end
  end

  def pop_tail(key)
    ensure_retry do
      write "RPOP #{key}\r\n"
      get_response
    end
  end    

  def list_set(key, index, val)
    ensure_retry do
      write "LSET #{key} #{index} #{val.to_s.size}\r\n#{val}\r\n"
      get_response == OK
    end
  end

  def list_length(key)
    ensure_retry do
      write "LLEN #{key}\r\n"
      case i = get_response
      when -2
        raise RedisError, "key: #{key} does not hold a list value"
      else
        i
      end
    end
  end

  def list_range(key, start, ending)
    ensure_retry do
      write "LRANGE #{key} #{start} #{ending}\r\n"
      get_response
    end
  end

  def list_trim(key, start, ending)
    ensure_retry do
      write "LTRIM #{key} #{start} #{ending}\r\n"
      get_response
    end
  end

  def list_index(key, index)
    ensure_retry do
      write "LINDEX #{key} #{index}\r\n"
      get_response
    end
  end

  def list_rm(key, count, value)
    ensure_retry do    
      write "LREM #{key} #{count} #{value.to_s.size}\r\n#{value}\r\n"
      case num = get_response
      when -1
        raise RedisError, "key: #{key} does not exist"
      when -2
        raise RedisError, "key: #{key} does not hold a list value"
      else
        num
      end
    end
  end 

  def set_add(key, member)
    ensure_retry do    
      write "SADD #{key} #{member.to_s.size}\r\n#{member}\r\n"
      case get_response
      when 1
        true
      when 0
        false
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      end
    end
  end

  def set_delete(key, member)
    ensure_retry do    
      write "SREM #{key} #{member.to_s.size}\r\n#{member}\r\n"
      case get_response
      when 1
        true
      when 0
        false
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      end
    end
  end

  def set_count(key)
    ensure_retry do    
      write "SCARD #{key}\r\n"
      case i = get_response
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      else
        i
      end
    end
  end

  def set_member?(key, member)
    ensure_retry do    
      write "SISMEMBER #{key} #{member.to_s.size}\r\n#{member}\r\n"
      case get_response
      when 1
        true
      when 0
        false
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      end
    end
  end

  def set_members(key)
    ensure_retry do    
      write "SMEMBERS #{key}\r\n"
      Set.new(get_response)
    end
  end

  def set_intersect(*keys)
    ensure_retry do    
      write "SINTER #{keys.join(' ')}\r\n"
      Set.new(get_response)
    end
  end

  def set_inter_store(destkey, *keys)
    ensure_retry do    
      write "SINTERSTORE #{destkey} #{keys.join(' ')}\r\n"
      get_response
    end
  end

  def sort(key, opts={})
    ensure_retry do
      cmd = "SORT #{key}"
      cmd << " BY #{opts[:by]}" if opts[:by]
      cmd << " GET #{opts[:get]}" if opts[:get]
      cmd << " INCR #{opts[:incr]}" if opts[:incr]
      cmd << " DEL #{opts[:del]}" if opts[:del]
      cmd << " DECR #{opts[:decr]}" if opts[:decr]
      cmd << " #{opts[:order]}" if opts[:order]
      cmd << " LIMIT #{opts[:limit].join(' ')}" if opts[:limit]
      cmd << "\r\n"
      write(cmd)
      get_response
    end
  end
      
  def multi_bulk
    res = read_proto
    puts "mb res is #{res.inspect}" if $debug
    list = []
    Integer(res).times do
      vf = get_response
      puts "curren vf is #{vf.inspect}" if $debug
      list << vf
      puts "current list is #{list.inspect}" if $debug
    end
    list
  end
   
  def get_reply
    begin
      r = read(1)
      raise RedisError if (r == "\r" || r == "\n")
    rescue RedisError
      retry
    end
    r
  end
   
  def []=(key, val)
    ensure_retry do
      set(key,val)
    end
  end
  

  def set(key, val, expiry=nil)
    ensure_retry do
      write("SET #{key} #{val.to_s.size}\r\n#{val}\r\n")
      get_response == OK
    end
  end

  def set_unless_exists(key, val)
    ensure_retry do
      write "SETNX #{key} #{val.to_s.size}\r\n#{val}\r\n"
      get_response == 1
    end
  end  
  
  def status_code_reply
    begin
      res = read_proto  
      if res.index('-') == 0          
        raise RedisError, res
      else          
        true
      end
    rescue RedisError
       raise RedisError
    end
  end
  
  def get_response
    begin
      rtype = get_reply
    rescue => e
      raise RedisError, e.inspect
    end
    puts "reply_type is #{rtype.inspect}" if $debug
    case rtype
    when SINGLE
      single_line
    when BULK
      bulk_reply
    when MULTI
      multi_bulk
    when INT
      integer_reply
    when ERR
      raise RedisError, single_line
    else
      raise RedisError, "Unknown response.."
    end
  end
  
  def integer_reply
    Integer(read_proto)
  end
  
  def single_line
    buff = ""
    while buff[-2..-1] != "\r\n"
      buff << read(1)
    end
    puts "single_line value is #{buff[0..-3].inspect}" if $debug
    buff[0..-3]
  end
  
  def read_proto
    with_socket_management(@server) do |socket|
      if res = socket.gets
        x = res.chomp
        puts "read_proto is #{x.inspect}\n\n" if $debug
        x.to_i
      end
    end
  end
  
end