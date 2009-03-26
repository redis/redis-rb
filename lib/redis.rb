require 'socket'
require 'set'
require File.join(File.dirname(__FILE__),'server')


class RedisError < StandardError
end
class RedisRenameError < StandardError
end
class Redis
  ERRCODE = "-".freeze
  attr_reader :servers
  
  
  def initialize()
    $debug = false
    self.servers=['localhost:6397']
  end
  
  def ensure_raise(&block)
    begin
      yield block
    rescue
      raise RedisError
    end
  end
  
  def ensure_retry(&block)
    begin
      yield block
    rescue RedisError
      retry
    end
  end
  
  def servers=(servers)
    # Create the server objects.
    @servers = Array(servers).collect do |server|
      case server
      when String
        host, port, replica = server.split ':', 3
        Server.new(self, host, port, replica)
      else
        server
      end
    end

    puts "Servers now: #{@servers.inspect}" if $debug

    @servers
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
      value_for(reply_type)
  end
  
  def select_db(index)
    ensure_retry do
      write "SELECT #{index}\r\n"
     x = value_for(reply_type)
    end
  end
  
  def flush_db
    ensure_retry do
      write "FLUSHDB\r\n"
      value_for(reply_type)
    end
  end    

  def last_save
    ensure_retry do
      write "LASTSAVE\r\n"
      value_for(reply_type).to_i
    end
  end
  
  def bgsave
    ensure_retry do
      write "BGSAVE\r\n"
      value_for(reply_type)
    end
  end  
    
  def info
   info = {}
   info = ensure_retry do
      write("INFO\r\n")
      x = value_for(reply_type)
      x.each do |kv|
        k,v = kv.split(':', 2)
        k,v = k.chomp, v = v.chomp
        info[k.to_sym] = v
      end
      info
    end
  end
  
  
  def bulk_reply(marshal=false)
    begin
      if marshal
        x = Marshal.load(read)
      else
        x = read
        x.chomp
      end
      puts "bulk_reply read value is #{x.inspect}" if $debug
      return x
    rescue => e
      puts "error in bulk_reply #{e}" if $debug
      nil
    end
  end
  
  def write(data)
    with_socket_management(@servers[0]) do |socket|
      puts "writing: #{data}" if $debug
      socket.write(data)
    end
  end
  
  def fetch(len)
    with_socket_management(@servers[0]) do |socket|
      len = [0, len.to_i].max
      res = socket.read(len + 2)
      res = res.chop if res
      res
    end
  end
  
  def read(length = read_proto)
    with_socket_management(@servers[0]) do |socket|
      res = socket.read(length)
      puts "read is #{res.inspect}" if $debug
      res
    end
  end

  def keys(glob)
    ensure_retry do
      write "KEYS #{glob}\r\n"
      value_for(reply_type,false).split(' ')
    end
  end

  def rename!(oldkey, newkey)
    ensure_retry do
      write "RENAME #{oldkey} #{newkey}\r\n"
      value_for(reply_type,false)
    end
  end  
  
  def rename(oldkey, newkey)
    ensure_retry do
      write "RENAMENX #{oldkey} #{newkey}\r\n"
      case value_for(reply_type,false)
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
      value_for(reply_type,false) == 1
    end
  end  
  
  def delete(key)
    ensure_retry do
      write "DEL #{key}\r\n"
      value_for(reply_type,false) == 1
    end
  end  
  
  def [](key)
    ensure_retry do
      get(key,false)
    end
  end

  def get(key,marshal=false)
    ensure_retry do
      write "GET #{key}\r\n"
      value_for(reply_type,marshal)
    end
  end
  
  def mget(marshal=false, *keys)
    ensure_retry do
      write "MGET #{keys.join(' ')}\r\n"
      value_for(reply_type,marshal)
    end
  end

  def incr(key, increment=nil)
    ensure_retry do
      if increment
        write "INCRBY #{key} #{increment}\r\n"
      else
        write "INCR #{key}\r\n"
      end    
      value_for(reply_type,false)
    end
  end

  def decr(key, decrement=nil)
    ensure_retry do
      if decrement
        write "DECRRBY #{key} #{decrement}\r\n"
      else
        write "DECR #{key}\r\n"
      end    
      value_for(reply_type,false)
    end
  end
  
  def randkey
    ensure_retry do
      write "RANDOMKEY\r\n"
      value_for(reply_type,false)
    end
  end

  def list_length(key)
    ensure_retry do
      write "LLEN #{key}\r\n"
      case i = value_for(reply_type,false)
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
      value_for(reply_type,false)
    end
  end
  
  def push_tail(key, string)
    ensure_retry do
      write "RPUSH #{key} #{string.to_s.size}\r\n#{string.to_s}\r\n"
      value_for(reply_type,false)
    end
  end      

  def push_head(key, string)
    ensure_retry do
      write "LPUSH #{key} #{string.to_s.size}\r\n#{string.to_s}\r\n"
      value_for(reply_type,false)
    end
  end
  
  def pop_head(key)
    ensure_retry do
      write "LPOP #{key}\r\n"
      value_for(reply_type,false)
    end
  end

  def pop_tail(key)
    ensure_retry do
      write "RPOP #{key}\r\n"
      value_for(reply_type,false)
    end
  end    

  def list_set(key, index, val)
    ensure_retry do
      write "LSET #{key} #{index} #{val.to_s.size}\r\n#{val}\r\n"
      value_for(reply_type,false)
    end
  end

  def list_length(key)
    ensure_retry do
      write "LLEN #{key}\r\n"
      case i = value_for(reply_type,false)
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
      value_for(reply_type,false)
    end
  end

  def list_trim(key, start, ending)
    ensure_retry do
      write "LTRIM #{key} #{start} #{ending}\r\n"
      value_for(reply_type,false)
    end
  end

  def list_index(key, index)
    ensure_retry do
      write "LINDEX #{key} #{index}\r\n"
      value_for(reply_type,false)
    end
  end

  def list_rm(key, count, value)
    ensure_retry do    
      write "LREM #{key} #{count} #{value.to_s.size}\r\n#{value}\r\n"
      case num = value_for(reply_type,false)
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
      case value_for(reply_type,false)
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
      case value_for(reply_type,false)
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
      case i = value_for(reply_type,false)
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
      case value_for(reply_type,false)
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
      Set.new(value_for(reply_type,false))
    end
  end

  def set_intersect(*keys)
    ensure_retry do    
      write "SINTER #{keys.join(' ')}\r\n"
      Set.new(value_for(reply_type,false))
    end
  end

  def set_inter_store(destkey, *keys)
    ensure_retry do    
      write "SINTERSTORE #{destkey} #{keys.join(' ')}\r\n"
      value_for(reply_type,false)
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
      write cmd
      value_for(reply_type,false)
    end
  end
      
  def multi_bulk(marshal=false)
   res = read_proto
   puts "mb res is #{res.inspect}" if $debug
   list = []
   Integer(res).times do
     vf = value_for(reply_type)
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
      set(key,val,nil,false)
    end
  end
  
  def set(key, val, marshal=false, expiry=nil)
    val = Marshal.dump(val) if marshal
     ensure_retry do
        write("SET #{key} #{val.to_s.size}\r\n#{val}\r\n")
        x = value_for(reply_type)
        puts "set x is #{x.inspect}" if $debug
        unless x
          raise RedisError
        end
        #'OK'
      end
  end

  def set_unless_exists(key, val, marshal=false)
    val = Marshal.dump(val) if marshal
    ensure_retry do
      write "SETNX #{key} #{val.to_s.size}\r\n#{val}\r\n"
      value_for(reply_type) == 1
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

  def value_for(rtype, marshal=false)
    puts "rtype in vf is #{rtype.inspect}" if $debug
      case rtype
        when 'bulk'
          bulk_reply(marshal)
        when 'single_line'
          single_line(marshal)
        when 'multi_bulk'
          multi_bulk(marshal)
        when 'integer'
          integer_reply
        else
          raise RedisError, "Quiting..."
          #exit
      end
  end

  def reply_type
    rtype = ensure_raise do
     get_reply
    end
    puts "reply_type is #{rtype.inspect}" if $debug
    
    case rtype
      when '-'
        'error'
      when '+'
        'single_line'
      when '$'
        'bulk'
      when '*'
        'multi_bulk'
      when ':'
        'integer'
    end
  end
  
  def integer_reply
    Integer(read_proto)
  end
  
  def single_line(marshal=false)
    buff = ""
    while buff[-2..-1] != "\r\n"
      begin
      buff << read(1)
      rescue
        raise RedisError
      end
    end
    puts "single_line value is #{buff[0..-3].inspect}" if $debug
    marshal ? Marshal.load(buff[0..-3]) : buff[0..-3]
  end
  
  def read_proto
    with_socket_management(@servers[0]) do |socket|
      if res = socket.gets
        x = res.chop
        puts "read_proto is #{x.inspect}\n\n" if $debug
        x.to_i
      end
      
    end
  end
  
end