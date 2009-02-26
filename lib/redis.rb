require 'socket'
require 'timeout'

class RedisError < StandardError
end

class Redis
  OK = "+OK".freeze
  ERROR = "-".freeze
  NIL = 'nil'.freeze
  
  def initialize(opts={})
    @opts = {:host => 'localhost', :port => '6379'}.merge(opts)
  end
  
  # SET <key> <value>
  # Time complexity: O(1)
  #     Set the string <value> as value of the key.
  #     The string can't be longer than 1073741824 bytes (1 GB).
  def []=(key, val)
    write "SET #{key} #{val.size}\r\n#{val}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end    
  end
  
  # SETNX <key> <value>
  # Time complexity: O(1)
  #     SETNX works exactly like SET with the only difference that
  #     if the key already exists no operation is performed.
  #     SETNX actually means "SET if Not eXists".
  def set_unless_exists(key, val)
    write "SETNX #{key} #{val.size}\r\n#{val}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end    
  end
  
  # GET <key>
  # Time complexity: O(1)
  #     Get the value of the specified key. If the key
  #     does not exist the special value 'nil' is returned.
  #     If the value stored at <key> is not a string an error
  #     is returned because GET can only handle string values.
  def [](key)
    write "GET #{key}\r\n"
    res = read_proto
    if res != NIL
      val = read(res.to_i)
      nibble_end
      val
    else
      nil
    end    
  end
  
  # INCR <key>
  # Time complexity: O(1)
  #     Increment the number stored at <key> by one. If the key does
  #     not exist set the key to the value of "1" (like if the previous
  #     value was zero). If the value at <key> is not a string value
  #     an error is returned.
  def incr(key)
    write "INCR #{key}\r\n"
    read_proto.to_i
  end
  
  # !! SEEMS BROKEN IN REDIS SERVER RIGHT NOW !!
  # INCRBY <key> <num>
  # INCRBY works just like INCR but instead to increment by 1 the
  #     increment is <num>.
  def incrby(key, num)
    write "INCRBY #{key} #{num}\r\n"
    read_proto.to_i
  end
  
  # DECR <key>
  # Time complexity: O(1)
  #     Decrement the number stored at <key> by one. If the key does
  #     not exist set the key to the value of "-1" (like if the previous
  #     value was zero). If the value at <key> is not a string value
  #     an error is returned.
  def decr(key)
    write "DECR #{key}\r\n"
    read_proto.to_i
  end
  
  # !! SEEMS BROKEN IN REDIS SERVER RIGHT NOW !!
  # DECRBY <key> <num>
  # DECRBY works just like DECR but instead to decrement by 1 the
  #    decrement is <value>.
  def decrby(key, num)
    write "DECRBY #{key} #{num}\r\n"
    read_proto.to_i
  end
  
  # RANDOMKEY
  # Time complexity: O(1)
  #     Returns a random key from the currently seleted DB.
  def randkey
    write "RANDOMKEY\r\n"
    read_proto
  end

  # RENAME <oldkey> <newkey>
  #     Atomically renames the key <oldkey> to <newkey>. If the source and
  #     destination name are the same an error is returned. If <newkey>
  #     already exists it is overwritten.
  def rename!(oldkey, newkey)
    write "RENAME #{oldkey} #{newkey}\r\n"
    res = read_proto
    if res == OK
      newkey
    else
      raise RedisError, res.inspect
    end
  end
  
  # RENAMENX <oldkey> <newkey>
  #     Just like RENAME but fails if the destination key <newkey>
  #     already exists.
  def rename(oldkey, newkey)
    write "RENAMENX #{oldkey} #{newkey}\r\n"
    res = read_proto
    if res == OK
      newkey
    else
      raise RedisError, res.inspect
    end
  end
  
  # EXISTS <key>
  # Time complexity: O(1)
  #     Test of the specified key exists. The command returns
  #     "0" if the key exists, otherwise "1" is returned.
  #     Note that even keys set with an empty string as value will
  #     return "1".
  def key?(key)
    write "EXISTS #{key}\r\n"
    read_proto.to_i == 1
  end
  
  # DEL <key>
  # Time complexity: O(1)
  #     Remove the specified key. If the key does not exist
  #     no operation is performed. The command always returns success.
  # 
  def delete(key)
    write "DEL #{key}\r\n"
    if read_proto == OK
      true
    else
      raise RedisError
    end
  end
  
  # KEYS <pattern>
  # Time complexity: O(n) (with n being the number of keys in the DB)
  #     Returns all the keys matching the glob-style <pattern> as
  #     space separated strings. For example if you have in the
  #     database the keys "foo" and "foobar" the command "KEYS foo*"
  #     will return "foo foobar".
  def keys(glob)
    write "KEYS #{glob}\r\n"
    res = read_proto
    if res
      keys = read(res.to_i).split(" ")
      nibble_end
      keys
    end
  end
  
  # !! SEEMS BROKEN IN REDIS SERVER RIGHT NOW !!
  # TYPE <key>
  # Time complexity: O(1)
  #     Return the type of the value stored at <key> in form of a
  #     string. The type can be one of "NONE","STRING","LIST","SET".
  #     NONE is returned if the key does not exist.
  def type?(key)
    write "TYPE #{key}\r\n"
    read_proto
  end
  
  # RPUSH <key> <string>
  # Time complexity: O(1)
  #     Add the given string to the head of the list contained at key.
  #     If the key does not exist an empty list is created just before
  #     the append operation. If the key exists but is not a List an error
  #     is returned.
  def push_head(key, string)
    write "RPUSH #{key} #{string.size}\r\n#{string}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  
  # LPUSH <key> <string>
  # Time complexity: O(1)
  #     Add the given string to the tail of the list contained at key.
  #     If the key does not exist an empty list is created just before
  #     the append operation. If the key exists but is not a List an error
  #     is returned.
  def push_tail(key, string)
    write "LPUSH #{key} #{string.size}\r\n#{string}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  
  # 
  # LLEN <key>
  # Time complexity: O(1)
  #     Return the length of the list stored at the specified key. If the
  #     key does not exist zero is returned (the same behaviour as for
  #     empty lists). If the value stored at key is not a list an error
  #     is returned.
  def list_length(key)
    write "LLEN #{key}\r\n"
    Integer(read_proto)
  end
  
  # 
  # LRANGE <key> <start> <end>
  # Time complexity: O(n) (with n being the length of the range)
  #     Return the specified elements of the list stored at the specified
  #     key. Start and end are zero-based indexes. 0 is the first element
  #     of the list (the list head), 1 the next element and so on.
  # 
  #     For example LRANGE foobar 0 2 will return the first three elements
  #     of the list.
  # 
  #     <start> and <end> can also be negative numbers indicating offsets
  #     from the end of the list. For example -1 is the last element of
  #     the list, -2 the penultimate element and so on.
  # 
  #     Indexes out of range will not produce an error: if start is over
  #     the end of the list, or start > end, an empty list is returned.
  #     If end over the end of the list Redis will threat it just like
  #     the last element of the list.
  def list_range(key, start, ending)
    write "LRANGE #{key} #{start} #{ending}\r\n"
    res = read_proto
    if res[0] = ERROR
      raise RedisError, read_proto
    else
      items = Integer(read_proto)
      list = []
      items.times do
        list << read(Integer(read_proto))
        nibble_end
      end  
      list
    end
  end
  
  # 
  # LTRIM <key> <start> <end>
  # Time complexity: O(n) (with n being len of list - len of range)
  #     Trim an existing list so that it will contain only the specified
  #     range of elements specified. Start and end are zero-based indexes.
  #     0 is the first element of the list (the list head), 1 the next element
  #     and so on.
  # 
  #     For example LTRIM foobar 0 2 will modify the list stored at foobar
  #     key so that only the first three elements of the list will remain.
  # 
  #     <start> and <end> can also be negative numbers indicating offsets
  #     from the end of the list. For example -1 is the last element of
  #     the list, -2 the penultimate element and so on.
  # 
  #     Indexes out of range will not produce an error: if start is over
  #     the end of the list, or start > end, an empty list is left as value.
  #     If end over the end of the list Redis will threat it just like
  #     the last element of the list.
  # 
  #     Hint: the obvious use of LTRIM is together with LPUSH/RPUSH. For example:
  # 
  #         LPUSH mylist <someelement>
  #         LTRIM mylist 0 99
  # 
  #     The above two commands will push elements in the list taking care that
  #     the list will not grow without limits. This is very useful when using
  #     Redis to store logs for example. It is important to note that when used
  #     in this way LTRIM is an O(1) operation because in the average case
  #     just one element is removed from the tail of the list.
  def list_trim(key, start, ending)
    write "LTRIM #{key} #{start} #{ending}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  
  # 
  # LINDEX <key> <index>
  # Time complexity: O(n) (with n being the length of the list)
  #     Return the specified element of the list stored at the specified
  #     key. 0 is the first element, 1 the second and so on. Negative indexes
  #     are supported, for example -1 is the last element, -2 the penultimate
  #     and so on.
  # 
  #     If the value stored at key is not of list type an error is returned.
  #     If the index is out of range an empty string is returned.
  # 
  #     Note that even if the average time complexity is O(n) asking for
  #     the first or the last element of the list is O(1).
  def list_index(key, index)
    write "LINDEX #{key} #{index}\r\n"
    res = read_proto
    if res != NIL
      val = read(res.to_i)
      nibble_end
      val
    else
      nil
    end    
  end
  
  # 
  # LPOP <key>
  # Time complexity: O(1)
  #     Atomically return and remove the first element of the list.
  #     For example if the list contains the elements "a","b","c" LPOP
  #     will return "a" and the list will become "b","c".
  # 
  #     If the <key> does not exist or the list is already empty the special
  #     value 'nil' is returned.
  def list_pop_head(key)
    write "LPOP #{key} #{index}\r\n"
    res = read_proto
    if res != NIL
      val = read(res.to_i)
      nibble_end
      val
    else
      nil
    end    
  end
  
  # RPOP <key>
  #     This command works exactly like LPOP, but the last element instead
  #     of the first element of the list is returned/deleted.
  def list_pop_tail(key)
    write "RPOP #{key} #{index}\r\n"
    res = read_proto
    if res != NIL
      val = read(res.to_i)
      nibble_end
      val
    else
      nil
    end    
  end
  
  # SELECT <index>
  #     Select the DB with having the specified zero-based numeric index.
  #     For default every new client connection is automatically selected
  #     to DB 0.
  def select_db(index)
    write "SELECT #{index}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  # 
  # MOVE <key> <index>
  #     Move the specified key from the currently selected DB to the specified
  #     destination DB. If a key with the same name exists in the destination
  #     DB an error is returned.
  def move(key, index)
    write "MOVE #{index}\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  
  # SAVE
  #     Save the DB on disk. The server hangs while the saving is not
  #     completed, no connection is served in the meanwhile. An OK code
  #     is returned when the DB was fully stored in disk.
  def save
    write "SAVE\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  
  # BGSAVE
  #     Save the DB in background. The OK code is immediately returned.
  #     Redis forks, the parent continues to server the clients, the child
  #     saves the DB on disk then exit. A client my be able to check if the
  #     operation succeeded using the LASTSAVE command.
  def bgsave
    write "BGSAVE\r\n"
    res = read_proto
    if res == OK
      true
    else
      raise RedisError, res.inspect
    end
  end
  
  # 
  # LASTSAVE
  #     Return the UNIX TIME of the last DB save executed with success.
  #     A client may check if a BGSAVE command succeeded reading the LASTSAVE
  #     value, then issuing a BGSAVE command and checking at regular intervals
  #     every N seconds if LASTSAVE changed.
  def bgsave
    write "LASTSAVE\r\n"
    read_proto
  end
  
  # 
  # SHUTDOWN
  #     Stop all the clients, save the DB, then quit the server. This commands
  #     makes sure that the DB is switched off without the lost of any data.
  #     This is not guaranteed if the client uses simply "SAVE" and then
  #     "QUIT" because other clients may alter the DB data between the two
  #     commands.
  def bgsave
    write "SHUTDOWN\r\n"
    read_proto
  end
  
  def quit
    write "QUIT\r\n"
    read_proto
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
  rescue
    retries -= 1
    if retries > 0
      connect
      retry
    end
  end
  
  def write(data)
    retries = 3
    socket.write(data)
  rescue
    retries -= 1
    if retries > 0
      connect
      retry
    end
  end
  
  def nibble_end
    read(2)
  end
  
  def read_proto
    buff = ""
    while (char = read(1))
      buff << char
      break if buff[-2..-1] == "\r\n"
    end
    buff[0..-3]
  end
  
end
