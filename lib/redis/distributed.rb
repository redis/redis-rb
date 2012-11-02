require "redis/hash_ring"

class Redis
  class Distributed

    class CannotDistribute < RuntimeError
      def initialize(command)
        @command = command
      end

      def message
        "#{@command.to_s.upcase} cannot be used in Redis::Distributed because the keys involved need to be on the same server or because we cannot guarantee that the operation will be atomic."
      end
    end

    attr_reader :ring

    def initialize(node_configs, options = {})
      @tag = options.delete(:tag) || /^\{(.+?)\}/
      @default_options = options
      @ring = HashRing.new
      node_configs.each { |node_config| add_node(node_config) }
      @subscribed_node = nil
    end

    def node_for(key)
      @ring.get_node(key_tag(key.to_s) || key.to_s)
    end

    def nodes
      @ring.nodes
    end

    def add_node(options)
      options = { :url => options } if options.is_a?(String)
      options = @default_options.merge(options)
      @ring.add_node Redis.new( options )
    end

    # Change the selected database for the current connection.
    def select(db)
      on_each_node :select, db
    end

    # Ping the server.
    def ping
      on_each_node :ping
    end

    # Echo the given string.
    def echo(value)
      on_each_node :echo, value
    end

    # Close the connection.
    def quit
      on_each_node :quit
    end

    # Asynchronously save the dataset to disk.
    def bgsave
      on_each_node :bgsave
    end

    # Return the number of keys in the selected database.
    def dbsize
      on_each_node :dbsize
    end

    # Remove all keys from all databases.
    def flushall
      on_each_node :flushall
    end

    # Remove all keys from the current database.
    def flushdb
      on_each_node :flushdb
    end

    # Get information and statistics about the server.
    def info(cmd = nil)
      on_each_node :info, cmd
    end

    # Get the UNIX time stamp of the last successful save to disk.
    def lastsave
      on_each_node :lastsave
    end

    # Listen for all requests received by the server in real time.
    def monitor
      raise NotImplementedError
    end

    # Synchronously save the dataset to disk.
    def save
      on_each_node :save
    end

    # Get server time: an UNIX timestamp and the elapsed microseconds in the current second.
    def time
      on_each_node :time
    end

    # Remove the expiration from a key.
    def persist(key)
      node_for(key).persist(key)
    end

    # Set a key's time to live in seconds.
    def expire(key, seconds)
      node_for(key).expire(key, seconds)
    end

    # Set the expiration for a key as a UNIX timestamp.
    def expireat(key, unix_time)
      node_for(key).expireat(key, unix_time)
    end

    # Get the time to live (in seconds) for a key.
    def ttl(key)
      node_for(key).ttl(key)
    end

    # Set a key's time to live in milliseconds.
    def pexpire(key, milliseconds)
      node_for(key).pexpire(key, milliseconds)
    end

    # Set the expiration for a key as number of milliseconds from UNIX Epoch.
    def pexpireat(key, ms_unix_time)
      node_for(key).pexpireat(key, ms_unix_time)
    end

    # Get the time to live (in milliseconds) for a key.
    def pttl(key)
      node_for(key).pttl(key)
    end

    # Delete a key.
    def del(*args)
      keys_per_node = args.group_by { |key| node_for(key) }
      keys_per_node.inject(0) do |sum, (node, keys)|
        sum + node.del(*keys)
      end
    end

    # Determine if a key exists.
    def exists(key)
      node_for(key).exists(key)
    end

    # Find all keys matching the given pattern.
    def keys(glob = "*")
      on_each_node(:keys, glob).flatten
    end

    # Move a key to another database.
    def move(key, db)
      node_for(key).move(key, db)
    end

    # Return a random key from the keyspace.
    def randomkey
      raise CannotDistribute, :randomkey
    end

    # Rename a key.
    def rename(old_name, new_name)
      ensure_same_node(:rename, [old_name, new_name]) do |node|
        node.rename(old_name, new_name)
      end
    end

    # Rename a key, only if the new key does not exist.
    def renamenx(old_name, new_name)
      ensure_same_node(:renamenx, [old_name, new_name]) do |node|
        node.renamenx(old_name, new_name)
      end
    end

    # Sort the elements in a list, set or sorted set.
    def sort(key, options = {})
      keys = [key, options[:by], options[:store], *Array(options[:get])].compact

      ensure_same_node(:sort, keys) do |node|
        node.sort(key, options)
      end
    end

    # Determine the type stored at key.
    def type(key)
      node_for(key).type(key)
    end

    # Decrement the integer value of a key by one.
    def decr(key)
      node_for(key).decr(key)
    end

    # Decrement the integer value of a key by the given number.
    def decrby(key, decrement)
      node_for(key).decrby(key, decrement)
    end

    # Increment the integer value of a key by one.
    def incr(key)
      node_for(key).incr(key)
    end

    # Increment the integer value of a key by the given integer number.
    def incrby(key, increment)
      node_for(key).incrby(key, increment)
    end

    # Increment the numeric value of a key by the given float number.
    def incrbyfloat(key, increment)
      node_for(key).incrbyfloat(key, increment)
    end

    # Set the string value of a key.
    def set(key, value)
      node_for(key).set(key, value)
    end

    # Set the time to live in seconds of a key.
    def setex(key, ttl, value)
      node_for(key).setex(key, ttl, value)
    end

    # Set the time to live in milliseconds of a key.
    def psetex(key, ttl, value)
      node_for(key).psetex(key, ttl, value)
    end

    # Set the value of a key, only if the key does not exist.
    def setnx(key, value)
      node_for(key).setnx(key, value)
    end

    # Set multiple keys to multiple values.
    def mset(*args)
      raise CannotDistribute, :mset
    end

    def mapped_mset(hash)
      raise CannotDistribute, :mapped_mset
    end

    # Set multiple keys to multiple values, only if none of the keys exist.
    def msetnx(*args)
      raise CannotDistribute, :msetnx
    end

    def mapped_msetnx(hash)
      raise CannotDistribute, :mapped_msetnx
    end

    # Get the value of a key.
    def get(key)
      node_for(key).get(key)
    end

    # Get the values of all the given keys.
    def mget(*keys)
      raise CannotDistribute, :mget
    end

    def mapped_mget(*keys)
      raise CannotDistribute, :mapped_mget
    end

    # Overwrite part of a string at key starting at the specified offset.
    def setrange(key, offset, value)
      node_for(key).setrange(key, offset, value)
    end

    # Get a substring of the string stored at a key.
    def getrange(key, start, stop)
      node_for(key).getrange(key, start, stop)
    end

    # Sets or clears the bit at offset in the string value stored at key.
    def setbit(key, offset, value)
      node_for(key).setbit(key, offset, value)
    end

    # Returns the bit value at offset in the string value stored at key.
    def getbit(key, offset)
      node_for(key).getbit(key, offset)
    end

    # Append a value to a key.
    def append(key, value)
      node_for(key).append(key, value)
    end

    # Count the number of set bits in a range of the string value stored at key.
    def bitcount(key, start = 0, stop = -1)
      node_for(key).bitcount(key, start, stop)
    end

    # Perform a bitwise operation between strings and store the resulting string in a key.
    def bitop(operation, destkey, *keys)
      ensure_same_node(:bitop, [destkey] + keys) do |node|
        node.bitop(operation, destkey, *keys)
      end
    end

    # Set the string value of a key and return its old value.
    def getset(key, value)
      node_for(key).getset(key, value)
    end

    # Get the length of the value stored in a key.
    def strlen(key)
      node_for(key).strlen(key)
    end

    def [](key)
      get(key)
    end

    def []=(key,value)
      set(key, value)
    end

    # Get the length of a list.
    def llen(key)
      node_for(key).llen(key)
    end

    # Prepend one or more values to a list.
    def lpush(key, value)
      node_for(key).lpush(key, value)
    end

    # Prepend a value to a list, only if the list exists.
    def lpushx(key, value)
      node_for(key).lpushx(key, value)
    end

    # Append one or more values to a list.
    def rpush(key, value)
      node_for(key).rpush(key, value)
    end

    # Append a value to a list, only if the list exists.
    def rpushx(key, value)
      node_for(key).rpushx(key, value)
    end

    # Remove and get the first element in a list.
    def lpop(key)
      node_for(key).lpop(key)
    end

    # Remove and get the last element in a list.
    def rpop(key)
      node_for(key).rpop(key)
    end

    # Remove the last element in a list, append it to another list and return
    # it.
    def rpoplpush(source, destination)
      ensure_same_node(:rpoplpush, [source, destination]) do |node|
        node.rpoplpush(source, destination)
      end
    end

    def _bpop(cmd, args)
      options = {}

      case args.last
      when Hash
        options = args.pop
      when Integer
        # Issue deprecation notice in obnoxious mode...
        options[:timeout] = args.pop
      end

      if args.size > 1
        # Issue deprecation notice in obnoxious mode...
      end

      keys = args.flatten

      ensure_same_node(cmd, keys) do |node|
        node.__send__(cmd, keys, options)
      end
    end

    # Remove and get the first element in a list, or block until one is
    # available.
    def blpop(*args)
      _bpop(:blpop, args)
    end

    # Remove and get the last element in a list, or block until one is
    # available.
    def brpop(*args)
      _bpop(:brpop, args)
    end

    # Pop a value from a list, push it to another list and return it; or block
    # until one is available.
    def brpoplpush(source, destination, options = {})
      case options
      when Integer
        # Issue deprecation notice in obnoxious mode...
        options = { :timeout => options }
      end

      ensure_same_node(:brpoplpush, [source, destination]) do |node|
        node.brpoplpush(source, destination, options)
      end
    end

    # Get an element from a list by its index.
    def lindex(key, index)
      node_for(key).lindex(key, index)
    end

    # Insert an element before or after another element in a list.
    def linsert(key, where, pivot, value)
      node_for(key).linsert(key, where, pivot, value)
    end

    # Get a range of elements from a list.
    def lrange(key, start, stop)
      node_for(key).lrange(key, start, stop)
    end

    # Remove elements from a list.
    def lrem(key, count, value)
      node_for(key).lrem(key, count, value)
    end

    # Set the value of an element in a list by its index.
    def lset(key, index, value)
      node_for(key).lset(key, index, value)
    end

    # Trim a list to the specified range.
    def ltrim(key, start, stop)
      node_for(key).ltrim(key, start, stop)
    end

    # Get the number of members in a set.
    def scard(key)
      node_for(key).scard(key)
    end

    # Add one or more members to a set.
    def sadd(key, member)
      node_for(key).sadd(key, member)
    end

    # Remove one or more members from a set.
    def srem(key, member)
      node_for(key).srem(key, member)
    end

    # Remove and return a random member from a set.
    def spop(key)
      node_for(key).spop(key)
    end

    # Get a random member from a set.
    def srandmember(key)
      node_for(key).srandmember(key)
    end

    # Move a member from one set to another.
    def smove(source, destination, member)
      ensure_same_node(:smove, [source, destination]) do |node|
        node.smove(source, destination, member)
      end
    end

    # Determine if a given value is a member of a set.
    def sismember(key, member)
      node_for(key).sismember(key, member)
    end

    # Get all the members in a set.
    def smembers(key)
      node_for(key).smembers(key)
    end

    # Subtract multiple sets.
    def sdiff(*keys)
      ensure_same_node(:sdiff, keys) do |node|
        node.sdiff(*keys)
      end
    end

    # Subtract multiple sets and store the resulting set in a key.
    def sdiffstore(destination, *keys)
      ensure_same_node(:sdiffstore, [destination] + keys) do |node|
        node.sdiffstore(destination, *keys)
      end
    end

    # Intersect multiple sets.
    def sinter(*keys)
      ensure_same_node(:sinter, keys) do |node|
        node.sinter(*keys)
      end
    end

    # Intersect multiple sets and store the resulting set in a key.
    def sinterstore(destination, *keys)
      ensure_same_node(:sinterstore, [destination] + keys) do |node|
        node.sinterstore(destination, *keys)
      end
    end

    # Add multiple sets.
    def sunion(*keys)
      ensure_same_node(:sunion, keys) do |node|
        node.sunion(*keys)
      end
    end

    # Add multiple sets and store the resulting set in a key.
    def sunionstore(destination, *keys)
      ensure_same_node(:sunionstore, [destination] + keys) do |node|
        node.sunionstore(destination, *keys)
      end
    end

    # Get the number of members in a sorted set.
    def zcard(key)
      node_for(key).zcard(key)
    end

    # Add one or more members to a sorted set, or update the score for members
    # that already exist.
    def zadd(key, *args)
      node_for(key).zadd(key, *args)
    end

    # Increment the score of a member in a sorted set.
    def zincrby(key, increment, member)
      node_for(key).zincrby(key, increment, member)
    end

    # Remove one or more members from a sorted set.
    def zrem(key, member)
      node_for(key).zrem(key, member)
    end

    # Get the score associated with the given member in a sorted set.
    def zscore(key, member)
      node_for(key).zscore(key, member)
    end

    # Return a range of members in a sorted set, by index.
    def zrange(key, start, stop, options = {})
      node_for(key).zrange(key, start, stop, options)
    end

    # Return a range of members in a sorted set, by index, with scores ordered
    # from high to low.
    def zrevrange(key, start, stop, options = {})
      node_for(key).zrevrange(key, start, stop, options)
    end

    # Determine the index of a member in a sorted set.
    def zrank(key, member)
      node_for(key).zrank(key, member)
    end

    # Determine the index of a member in a sorted set, with scores ordered from
    # high to low.
    def zrevrank(key, member)
      node_for(key).zrevrank(key, member)
    end

    # Remove all members in a sorted set within the given indexes.
    def zremrangebyrank(key, start, stop)
      node_for(key).zremrangebyrank(key, start, stop)
    end

    # Return a range of members in a sorted set, by score.
    def zrangebyscore(key, min, max, options = {})
      node_for(key).zrangebyscore(key, min, max, options)
    end

    # Return a range of members in a sorted set, by score, with scores ordered
    # from high to low.
    def zrevrangebyscore(key, max, min, options = {})
      node_for(key).zrevrangebyscore(key, max, min, options)
    end

    # Remove all members in a sorted set within the given scores.
    def zremrangebyscore(key, min, max)
      node_for(key).zremrangebyscore(key, min, max)
    end

    # Get the number of members in a particular score range.
    def zcount(key, min, max)
      node_for(key).zcount(key, min, max)
    end

    # Intersect multiple sorted sets and store the resulting sorted set in a new
    # key.
    def zinterstore(destination, keys, options = {})
      ensure_same_node(:zinterstore, [destination] + keys) do |node|
        node.zinterstore(destination, keys, options)
      end
    end

    # Add multiple sorted sets and store the resulting sorted set in a new key.
    def zunionstore(destination, keys, options = {})
      ensure_same_node(:zunionstore, [destination] + keys) do |node|
        node.zunionstore(destination, keys, options)
      end
    end

    # Get the number of fields in a hash.
    def hlen(key)
      node_for(key).hlen(key)
    end

    # Set the string value of a hash field.
    def hset(key, field, value)
      node_for(key).hset(key, field, value)
    end

    # Set the value of a hash field, only if the field does not exist.
    def hsetnx(key, field, value)
      node_for(key).hsetnx(key, field, value)
    end

    # Set multiple hash fields to multiple values.
    def hmset(key, *attrs)
      node_for(key).hmset(key, *attrs)
    end

    def mapped_hmset(key, hash)
      node_for(key).hmset(key, *hash.to_a.flatten)
    end

    # Get the value of a hash field.
    def hget(key, field)
      node_for(key).hget(key, field)
    end

    # Get the values of all the given hash fields.
    def hmget(key, *fields)
      node_for(key).hmget(key, *fields)
    end

    def mapped_hmget(key, *fields)
      Hash[*fields.zip(hmget(key, *fields)).flatten]
    end

    # Delete one or more hash fields.
    def hdel(key, field)
      node_for(key).hdel(key, field)
    end

    # Determine if a hash field exists.
    def hexists(key, field)
      node_for(key).hexists(key, field)
    end

    # Increment the integer value of a hash field by the given integer number.
    def hincrby(key, field, increment)
      node_for(key).hincrby(key, field, increment)
    end

    # Increment the numeric value of a hash field by the given float number.
    def hincrbyfloat(key, field, increment)
      node_for(key).hincrbyfloat(key, field, increment)
    end

    # Get all the fields in a hash.
    def hkeys(key)
      node_for(key).hkeys(key)
    end

    # Get all the values in a hash.
    def hvals(key)
      node_for(key).hvals(key)
    end

    # Get all the fields and values in a hash.
    def hgetall(key)
      node_for(key).hgetall(key)
    end

    # Post a message to a channel.
    def publish(channel, message)
      node_for(channel).publish(channel, message)
    end

    def subscribed?
      !! @subscribed_node
    end

    # Listen for messages published to the given channels.
    def subscribe(channel, *channels, &block)
      if channels.empty?
        @subscribed_node = node_for(channel)
        @subscribed_node.subscribe(channel, &block)
      else
        ensure_same_node(:subscribe, [channel] + channels) do |node|
          @subscribed_node = node
          node.subscribe(channel, *channels, &block)
        end
      end
    end

    # Stop listening for messages posted to the given channels.
    def unsubscribe(*channels)
      raise RuntimeError, "Can't unsubscribe if not subscribed." unless subscribed?
      @subscribed_node.unsubscribe(*channels)
    end

    # Listen for messages published to channels matching the given patterns.
    def psubscribe(*channels, &block)
      raise NotImplementedError
    end

    # Stop listening for messages posted to channels matching the given
    # patterns.
    def punsubscribe(*channels)
      raise NotImplementedError
    end

    # Watch the given keys to determine execution of the MULTI/EXEC block.
    def watch(*keys)
      raise CannotDistribute, :watch
    end

    # Forget about all watched keys.
    def unwatch
      raise CannotDistribute, :unwatch
    end

    def pipelined
      raise CannotDistribute, :pipelined
    end

    # Mark the start of a transaction block.
    def multi
      raise CannotDistribute, :multi
    end

    # Execute all commands issued after MULTI.
    def exec
      raise CannotDistribute, :exec
    end

    # Discard all commands issued after MULTI.
    def discard
      raise CannotDistribute, :discard
    end

    # Control remote script registry.
    def script(subcommand, *args)
      on_each_node(:script, subcommand, *args)
    end

    def _eval(cmd, args)
      script = args.shift
      options = args.pop if args.last.is_a?(Hash)
      options ||= {}

      keys = args.shift || options[:keys] || []
      argv = args.shift || options[:argv] || []

      ensure_same_node(cmd, keys) do |node|
        node.send(cmd, script, keys, argv)
      end
    end

    # Evaluate Lua script.
    def eval(*args)
      _eval(:eval, args)
    end

    # Evaluate Lua script by its SHA.
    def evalsha(*args)
      _eval(:evalsha, args)
    end

    def inspect
      "#<Redis client v#{Redis::VERSION} for #{nodes.map(&:id).join(', ')}>"
    end

  protected

    def on_each_node(command, *args)
      nodes.map do |node|
        node.send(command, *args)
      end
    end

    def node_index_for(key)
      nodes.index(node_for(key))
    end

    def key_tag(key)
      key.to_s[@tag, 1] if @tag
    end

    def ensure_same_node(command, keys)
      all = true

      tags = keys.map do |key|
        tag = key_tag(key)
        all = false unless tag
        tag
      end

      if (all && tags.uniq.size != 1) || (!all && keys.uniq.size != 1)
        # Not 1 unique tag or not 1 unique key
        raise CannotDistribute, command
      end

      yield(node_for(keys.first))
    end
  end
end
