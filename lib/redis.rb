require 'socket'

class Redis
  VERSION = "2.1.1"

  class ProtocolError < RuntimeError
    def initialize(reply_type)
      super(<<-EOS.gsub(/(?:^|\n)\s*/, " "))
      Got '#{reply_type}' as initial reply byte.
      If you're running in a multi-threaded environment, make sure you
      pass the :thread_safe option when initializing the connection.
      If you're in a forking environment, such as Unicorn, you need to
      connect to Redis after forking.
      EOS
    end
  end

  def self.deprecate(message, trace = caller[0])
    $stderr.puts "\n#{message} (in #{trace})"
  end

  attr :client

  def self.connect(options = {})
    options = options.dup

    require "uri"

    url = URI(options.delete(:url) || ENV["REDIS_URL"] || "redis://127.0.0.1:6379/0")

    options[:host]     ||= url.host
    options[:port]     ||= url.port
    options[:password] ||= url.password
    options[:db]       ||= url.path[1..-1].to_i

    new(options)
  end

  def self.current
    Thread.current[:redis] ||= Redis.connect
  end

  def self.current=(redis)
    Thread.current[:redis] = redis
  end

  def initialize(options = {})
    if options[:thread_safe]
      @client = Client::ThreadSafe.new(options)
    else
      @client = Client.new(options)
    end
  end

  # Authenticate to the server.
  def auth(password)
    @client.call(:auth, password)
  end

  # Change the selected database for the current connection.
  def select(db)
    @client.db = db
    @client.call(:select, db)
  end

  # Get information and statistics about the server.
  def info
    Hash[*@client.call(:info).split(/:|\r\n/).grep(/^[^#]/)]
  end

  def config(action, *args)
    response = @client.call(:config, action, *args)
    response = Hash[*response] if action == :get
    response
  end

  # Remove all keys from the current database.
  def flushdb
    @client.call(:flushdb)
  end

  # Remove all keys from all databases.
  def flushall
    @client.call(:flushall)
  end

  # Synchronously save the dataset to disk.
  def save
    @client.call(:save)
  end

  # Asynchronously save the dataset to disk.
  def bgsave
    @client.call(:bgsave)
  end

  # Asynchronously rewrite the append-only file.
  def bgrewriteaof
    @client.call(:bgrewriteaof)
  end

  # Get the value of a key.
  def get(key)
    @client.call(:get, key)
  end

  # Returns the bit value at offset in the string value stored at key.
  def getbit(key, offset)
    @client.call(:getbit, key, offset)
  end

  # Get a substring of the string stored at a key.
  def getrange(key, start, stop)
    @client.call(:getrange, key, start, stop)
  end

  # Set the string value of a key and return its old value.
  def getset(key, value)
    @client.call(:getset, key, value)
  end

  # Get the values of all the given keys.
  def mget(*keys)
    @client.call(:mget, *keys)
  end

  # Append a value to a key.
  def append(key, value)
    @client.call(:append, key, value)
  end

  def substr(key, start, stop)
    @client.call(:substr, key, start, stop)
  end

  # Get the length of the value stored in a key.
  def strlen(key)
    @client.call(:strlen, key)
  end

  # Get all the fields and values in a hash.
  def hgetall(key)
    Hash[*@client.call(:hgetall, key)]
  end

  # Get the value of a hash field.
  def hget(key, field)
    @client.call(:hget, key, field)
  end

  # Delete a hash field.
  def hdel(key, field)
    @client.call(:hdel, key, field)
  end

  # Get all the fields in a hash.
  def hkeys(key)
    @client.call(:hkeys, key)
  end

  # Find all keys matching the given pattern.
  def keys(pattern = "*")
    _array @client.call(:keys, pattern)
  end

  # Return a random key from the keyspace.
  def randomkey
    @client.call(:randomkey)
  end

  # Echo the given string.
  def echo(value)
    @client.call(:echo, value)
  end

  # Ping the server.
  def ping
    @client.call(:ping)
  end

  # Get the UNIX time stamp of the last successful save to disk.
  def lastsave
    @client.call(:lastsave)
  end

  # Return the number of keys in the selected database.
  def dbsize
    @client.call(:dbsize)
  end

  # Determine if a key exists.
  def exists(key)
    _bool @client.call(:exists, key)
  end

  # Get the length of a list.
  def llen(key)
    @client.call(:llen, key)
  end

  # Get a range of elements from a list.
  def lrange(key, start, stop)
    @client.call(:lrange, key, start, stop)
  end

  # Trim a list to the specified range.
  def ltrim(key, start, stop)
    @client.call(:ltrim, key, start, stop)
  end

  # Get an element from a list by its index.
  def lindex(key, index)
    @client.call(:lindex, key, index)
  end

  # Insert an element before or after another element in a list.
  def linsert(key, where, pivot, value)
    @client.call(:linsert, key, where, pivot, value)
  end

  # Set the value of an element in a list by its index.
  def lset(key, index, value)
    @client.call(:lset, key, index, value)
  end

  # Remove elements from a list.
  def lrem(key, count, value)
    @client.call(:lrem, key, count, value)
  end

  # Append a value to a list.
  def rpush(key, value)
    @client.call(:rpush, key, value)
  end

  # Append a value to a list, only if the list exists.
  def rpushx(key, value)
    @client.call(:rpushx, key, value)
  end

  # Prepend a value to a list.
  def lpush(key, value)
    @client.call(:lpush, key, value)
  end

  # Prepend a value to a list, only if the list exists.
  def lpushx(key, value)
    @client.call(:lpushx, key, value)
  end

  # Remove and get the last element in a list.
  def rpop(key)
    @client.call(:rpop, key)
  end

  # Remove and get the first element in a list, or block until one is available.
  def blpop(*args)
    @client.call_without_timeout(:blpop, *args)
  end

  # Remove and get the last element in a list, or block until one is available.
  def brpop(*args)
    @client.call_without_timeout(:brpop, *args)
  end

  # Pop a value from a list, push it to another list and return it; or block
  # until one is available.
  def brpoplpush(source, destination, timeout)
    @client.call_without_timeout(:brpoplpush, source, destination, timeout)
  end

  # Remove the last element in a list, append it to another list and return it.
  def rpoplpush(source, destination)
    @client.call(:rpoplpush, source, destination)
  end

  # Remove and get the first element in a list.
  def lpop(key)
    @client.call(:lpop, key)
  end

  # Get all the members in a set.
  def smembers(key)
    @client.call(:smembers, key)
  end

  # Determine if a given value is a member of a set.
  def sismember(key, member)
    _bool @client.call(:sismember, key, member)
  end

  # Add a member to a set.
  def sadd(key, value)
    _bool @client.call(:sadd, key, value)
  end

  # Remove a member from a set.
  def srem(key, value)
    _bool @client.call(:srem, key, value)
  end

  # Move a member from one set to another.
  def smove(source, destination, member)
    _bool @client.call(:smove, source, destination, member)
  end

  # Remove and return a random member from a set.
  def spop(key)
    @client.call(:spop, key)
  end

  # Get the number of members in a set.
  def scard(key)
    @client.call(:scard, key)
  end

  # Intersect multiple sets.
  def sinter(*keys)
    @client.call(:sinter, *keys)
  end

  # Intersect multiple sets and store the resulting set in a key.
  def sinterstore(destination, *keys)
    @client.call(:sinterstore, destination, *keys)
  end

  # Add multiple sets.
  def sunion(*keys)
    @client.call(:sunion, *keys)
  end

  # Add multiple sets and store the resulting set in a key.
  def sunionstore(destination, *keys)
    @client.call(:sunionstore, destination, *keys)
  end

  # Subtract multiple sets.
  def sdiff(*keys)
    @client.call(:sdiff, *keys)
  end

  # Subtract multiple sets and store the resulting set in a key.
  def sdiffstore(destination, *keys)
    @client.call(:sdiffstore, destination, *keys)
  end

  # Get a random member from a set.
  def srandmember(key)
    @client.call(:srandmember, key)
  end

  # Add a member to a sorted set, or update its score if it already exists.
  def zadd(key, score, member)
    _bool @client.call(:zadd, key, score, member)
  end

  # Determine the index of a member in a sorted set.
  def zrank(key, member)
    @client.call(:zrank, key, member)
  end

  # Determine the index of a member in a sorted set, with scores ordered from
  # high to low.
  def zrevrank(key, member)
    @client.call(:zrevrank, key, member)
  end

  # Increment the score of a member in a sorted set.
  def zincrby(key, increment, member)
    @client.call(:zincrby, key, increment, member)
  end

  # Get the number of members in a sorted set.
  def zcard(key)
    @client.call(:zcard, key)
  end

  # Return a range of members in a sorted set, by index.
  def zrange(key, start, stop, options = {})
    command = CommandOptions.new(options) do |c|
      c.bool :with_scores
    end

    @client.call(:zrange, key, start, stop, *command.to_a)
  end

  # Return a range of members in a sorted set, by score.
  def zrangebyscore(key, min, max, options = {})
    command = CommandOptions.new(options) do |c|
      c.splat :limit
      c.bool  :with_scores
    end

    @client.call(:zrangebyscore, key, min, max, *command.to_a)
  end

  # Count the members in a sorted set with scores within the given values.
  def zcount(key, start, stop)
    @client.call(:zcount, key, start, stop)
  end

  # Return a range of members in a sorted set, by index, with scores ordered
  # from high to low.
  def zrevrange(key, start, stop, options = {})
    command = CommandOptions.new(options) do |c|
      c.bool :with_scores
    end

    @client.call(:zrevrange, key, start, stop, *command.to_a)
  end

  # Return a range of members in a sorted set, by score, with scores ordered
  # from high to low.
  def zrevrangebyscore(key, max, min, options = {})
    command = CommandOptions.new(options) do |c|
      c.splat :limit
      c.bool  :with_scores
    end

    @client.call(:zrevrangebyscore, key, max, min, *command.to_a)
  end

  # Remove all members in a sorted set within the given scores.
  def zremrangebyscore(key, min, max)
    @client.call(:zremrangebyscore, key, min, max)
  end

  # Remove all members in a sorted set within the given indexes.
  def zremrangebyrank(key, start, stop)
    @client.call(:zremrangebyrank, key, start, stop)
  end

  # Get the score associated with the given member in a sorted set.
  def zscore(key, member)
    @client.call(:zscore, key, member)
  end

  # Remove a member from a sorted set.
  def zrem(key, member)
    _bool @client.call(:zrem, key, member)
  end

  # Intersect multiple sorted sets and store the resulting sorted set in a new
  # key.
  def zinterstore(destination, keys, options = {})
    command = CommandOptions.new(options) do |c|
      c.splat :weights
      c.value :aggregate
    end

    @client.call(:zinterstore, destination, keys.size, *(keys + command.to_a))
  end

  # Add multiple sorted sets and store the resulting sorted set in a new key.
  def zunionstore(destination, keys, options = {})
    command = CommandOptions.new(options) do |c|
      c.splat :weights
      c.value :aggregate
    end

    @client.call(:zunionstore, destination, keys.size, *(keys + command.to_a))
  end

  # Move a key to another database.
  def move(key, db)
    _bool @client.call(:move, key, db)
  end

  # Set the value of a key, only if the key does not exist.
  def setnx(key, value)
    _bool @client.call(:setnx, key, value)
  end

  # Delete a key.
  def del(*keys)
    @client.call(:del, *keys)
  end

  # Rename a key.
  def rename(old_name, new_name)
    @client.call(:rename, old_name, new_name)
  end

  # Rename a key, only if the new key does not exist.
  def renamenx(old_name, new_name)
    _bool @client.call(:renamenx, old_name, new_name)
  end

  # Set a key's time to live in seconds.
  def expire(key, seconds)
    _bool @client.call(:expire, key, seconds)
  end

  # Remove the expiration from a key.
  def persist(key)
    _bool @client.call(:persist, key)
  end

  # Get the time to live for a key.
  def ttl(key)
    @client.call(:ttl, key)
  end

  # Set the expiration for a key as a UNIX timestamp.
  def expireat(key, unix_time)
    _bool @client.call(:expireat, key, unix_time)
  end

  # Set the string value of a hash field.
  def hset(key, field, value)
    _bool @client.call(:hset, key, field, value)
  end

  # Set the value of a hash field, only if the field does not exist.
  def hsetnx(key, field, value)
    _bool @client.call(:hsetnx, key, field, value)
  end

  # Set multiple hash fields to multiple values.
  def hmset(key, *attrs)
    @client.call(:hmset, key, *attrs)
  end

  def mapped_hmset(key, hash)
    hmset(key, *hash.to_a.flatten)
  end

  # Get the values of all the given hash fields.
  def hmget(key, *fields)
    @client.call(:hmget, key, *fields)
  end

  def mapped_hmget(key, *fields)
    Hash[*fields.zip(hmget(key, *fields)).flatten]
  end

  # Get the number of fields in a hash.
  def hlen(key)
    @client.call(:hlen, key)
  end

  # Get all the values in a hash.
  def hvals(key)
    @client.call(:hvals, key)
  end

  # Increment the integer value of a hash field by the given number.
  def hincrby(key, field, increment)
    @client.call(:hincrby, key, field, increment)
  end

  # Discard all commands issued after MULTI.
  def discard
    @client.call(:discard)
  end

  # Determine if a hash field exists.
  def hexists(key, field)
    _bool @client.call(:hexists, key, field)
  end

  # Listen for all requests received by the server in real time.
  def monitor(&block)
    @client.call_loop(:monitor, &block)
  end

  def debug(*args)
    @client.call(:debug, *args)
  end

  # Internal command used for replication.
  def sync
    @client.call(:sync)
  end

  def [](key)
    get(key)
  end

  def []=(key,value)
    set(key, value)
  end

  # Set the string value of a key.
  def set(key, value)
    @client.call(:set, key, value)
  end

  # Sets or clears the bit at offset in the string value stored at key.
  def setbit(key, offset, value)
    @client.call(:setbit, key, offset, value)
  end

  # Set the value and expiration of a key.
  def setex(key, ttl, value)
    @client.call(:setex, key, ttl, value)
  end

  # Overwrite part of a string at key starting at the specified offset.
  def setrange(key, offset, value)
    @client.call(:setrange, key, offset, value)
  end

  # Set multiple keys to multiple values.
  def mset(*args)
    @client.call(:mset, *args)
  end

  def mapped_mset(hash)
    mset(*hash.to_a.flatten)
  end

  # Set multiple keys to multiple values, only if none of the keys exist.
  def msetnx(*args)
    @client.call(:msetnx, *args)
  end

  def mapped_msetnx(hash)
    msetnx(*hash.to_a.flatten)
  end

  def mapped_mget(*keys)
    Hash[*keys.zip(mget(*keys)).flatten]
  end

  # Sort the elements in a list, set or sorted set.
  def sort(key, options = {})
    command = CommandOptions.new(options) do |c|
      c.value :by
      c.splat :limit
      c.multi :get
      c.words :order
      c.value :store
    end

    @client.call(:sort, key, *command.to_a)
  end

  # Increment the integer value of a key by one.
  def incr(key)
    @client.call(:incr, key)
  end

  # Increment the integer value of a key by the given number.
  def incrby(key, increment)
    @client.call(:incrby, key, increment)
  end

  # Decrement the integer value of a key by one.
  def decr(key)
    @client.call(:decr, key)
  end

  # Decrement the integer value of a key by the given number.
  def decrby(key, decrement)
    @client.call(:decrby, key, decrement)
  end

  # Determine the type stored at key.
  def type(key)
    @client.call(:type, key)
  end

  # Close the connection.
  def quit
    @client.call(:quit)
  rescue Errno::ECONNRESET
  ensure
    @client.disconnect
  end

  # Synchronously save the dataset to disk and then shut down the server.
  def shutdown
    @client.call(:shutdown)
  end

  # Make the server a slave of another instance, or promote it as master.
  def slaveof(host, port)
    @client.call(:slaveof, host, port)
  end

  def pipelined
    original, @client = @client, Pipeline.new
    yield
    original.call_pipelined(@client.commands) unless @client.commands.empty?
  ensure
    @client = original
  end

  # Watch the given keys to determine execution of the MULTI/EXEC block.
  def watch(*keys)
    @client.call(:watch, *keys)
  end

  # Forget about all watched keys.
  def unwatch
    @client.call(:unwatch)
  end

  # Execute all commands issued after MULTI.
  def exec
    @client.call(:exec)
  end

  # Mark the start of a transaction block.
  def multi(&block)
    result = @client.call :multi

    return result unless block_given?

    begin
      yield(self)
    rescue Exception => e
      discard
      raise e
    end

    exec
  end

  # Post a message to a channel.
  def publish(channel, message)
    @client.call(:publish, channel, message)
  end

  def subscribed?
    @client.kind_of? SubscribedClient
  end

  # Stop listening for messages posted to the given channels.
  def unsubscribe(*channels)
    raise RuntimeError, "Can't unsubscribe if not subscribed." unless subscribed?
    @client.unsubscribe(*channels)
  end

  # Stop listening for messages posted to channels matching the given patterns.
  def punsubscribe(*channels)
    raise RuntimeError, "Can't unsubscribe if not subscribed." unless subscribed?
    @client.punsubscribe(*channels)
  end

  # Listen for messages published to the given channels.
  def subscribe(*channels, &block)
    subscription(:subscribe, channels, block)
  end

  # Listen for messages published to channels matching the given patterns.
  def psubscribe(*channels, &block)
    subscription(:psubscribe, channels, block)
  end

  def id
    @client.id
  end

  def inspect
    "#<Redis client v#{Redis::VERSION} connected to #{id} (Redis v#{info["redis_version"]})>"
  end

  def method_missing(command, *args)
    @client.call(command, *args)
  end

  class CommandOptions
    def initialize(options)
      @result = []
      @options = options
      yield(self)
    end

    def bool(name)
      insert(name) { |argument, value| [argument] }
    end

    def value(name)
      insert(name) { |argument, value| [argument, value] }
    end

    def splat(name)
      insert(name) { |argument, value| [argument, *value] }
    end

    def multi(name)
      insert(name) { |argument, value| [argument].product(Array(value)).flatten }
    end

    def words(name)
      insert(name) { |argument, value| value.split(" ") }
    end

    def to_a
      @result
    end

    def insert(name)
      @result += yield(name.to_s.upcase.gsub("_", ""), @options[name]) if @options[name]
    end
  end

private

  def _bool(value)
    value == 1
  end

  def _array(value)
    value.kind_of?(Array) ? value : value.split(" ")
  end

  def subscription(method, channels, block)
    return @client.call(method, *channels) if subscribed?

    begin
      original, @client = @client, SubscribedClient.new(@client)
      @client.send(method, *channels, &block)
    ensure
      @client = original
    end
  end

end

require "redis/connection" unless defined?(Redis::Connection)
require "redis/client"
require "redis/pipeline"
require "redis/subscribe"
require "redis/compat"
