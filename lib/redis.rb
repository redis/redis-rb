require "monitor"
require "redis/errors"

class Redis

  def self.deprecate(message, trace = caller[0])
    $stderr.puts "\n#{message} (in #{trace})"
  end

  attr :client

  # @deprecated The preferred way to create a new client object is using `#new`.
  #             This method does not actually establish a connection to Redis,
  #             in contrary to what you might expect.
  def self.connect(options = {})
    new(options)
  end

  def self.current
    @current ||= Redis.new
  end

  def self.current=(redis)
    @current = redis
  end

  include MonitorMixin

  def initialize(options = {})
    @client = Client.new(options)

    super() # Monitor#initialize
  end

  def synchronize
    mon_synchronize { yield(@client) }
  end

  # Run code with the client reconnecting
  def with_reconnect(val=true, &blk)
    synchronize do |client|
      client.with_reconnect(val, &blk)
    end
  end

  # Run code without the client reconnecting
  def without_reconnect(&blk)
    with_reconnect(false, &blk)
  end

  # Authenticate to the server.
  #
  # @param [String] password must match the password specified in the
  #   `requirepass` directive in the configuration file
  # @return [String] `OK`
  def auth(password)
    synchronize do |client|
      client.call([:auth, password])
    end
  end

  # Change the selected database for the current connection.
  #
  # @param [Fixnum] db zero-based index of the DB to use (0 to 15)
  # @return [String] `OK`
  def select(db)
    synchronize do |client|
      client.db = db
      client.call([:select, db])
    end
  end

  # Ping the server.
  #
  # @return [String] `PONG`
  def ping
    synchronize do |client|
      client.call([:ping])
    end
  end

  # Echo the given string.
  #
  # @param [String] value
  # @return [String]
  def echo(value)
    synchronize do |client|
      client.call([:echo, value])
    end
  end

  # Close the connection.
  #
  # @return [String] `OK`
  def quit
    synchronize do |client|
      begin
        client.call([:quit])
      rescue ConnectionError
      ensure
        client.disconnect
      end
    end
  end

  # Asynchronously rewrite the append-only file.
  #
  # @return [String] `OK`
  def bgrewriteaof
    synchronize do |client|
      client.call([:bgrewriteaof])
    end
  end

  # Asynchronously save the dataset to disk.
  #
  # @return [String] `OK`
  def bgsave
    synchronize do |client|
      client.call([:bgsave])
    end
  end

  # Get or set server configuration parameters.
  #
  # @param [String] action e.g. `get`, `set`, `resetstat`
  # @return [String, Hash] string reply, or hash when retrieving more than one
  #   property with `CONFIG GET`
  def config(action, *args)
    synchronize do |client|
      client.call([:config, action] + args) do |reply|
        if reply.kind_of?(Array) && action == :get
          Hash[reply.each_slice(2).to_a]
        else
          reply
        end
      end
    end
  end

  # Return the number of keys in the selected database.
  #
  # @return [Fixnum]
  def dbsize
    synchronize do |client|
      client.call([:dbsize])
    end
  end

  def debug(*args)
    synchronize do |client|
      client.call([:debug] + args)
    end
  end

  # Remove all keys from all databases.
  #
  # @return [String] `OK`
  def flushall
    synchronize do |client|
      client.call([:flushall])
    end
  end

  # Remove all keys from the current database.
  #
  # @return [String] `OK`
  def flushdb
    synchronize do |client|
      client.call([:flushdb])
    end
  end

  # Get information and statistics about the server.
  #
  # @param [String, Symbol] cmd e.g. "commandstats"
  # @return [Hash<String, String>]
  def info(cmd = nil)
    synchronize do |client|
      client.call([:info, cmd].compact) do |reply|
        if reply.kind_of?(String)
          reply = Hash[reply.split("\r\n").map do |line|
            line.split(":", 2) unless line =~ /^(#|$)/
          end.compact]

          if cmd && cmd.to_s == "commandstats"
            # Extract nested hashes for INFO COMMANDSTATS
            reply = Hash[reply.map do |k, v|
              v = v.split(",").map { |e| e.split("=") }
              [k[/^cmdstat_(.*)$/, 1], Hash[v]]
            end]
          end
        end

        reply
      end
    end
  end

  # Get the UNIX time stamp of the last successful save to disk.
  #
  # @return [Fixnum]
  def lastsave
    synchronize do |client|
      client.call([:lastsave])
    end
  end

  # Listen for all requests received by the server in real time.
  #
  # There is no way to interrupt this command.
  #
  # @yield a block to be called for every line of output
  # @yieldparam [String] line timestamp and command that was executed
  def monitor(&block)
    synchronize do |client|
      client.call_loop([:monitor], &block)
    end
  end

  # Synchronously save the dataset to disk.
  #
  # @return [String]
  def save
    synchronize do |client|
      client.call([:save])
    end
  end

  # Synchronously save the dataset to disk and then shut down the server.
  def shutdown
    synchronize do |client|
      client.with_reconnect(false) do
        begin
          client.call([:shutdown])
        rescue ConnectionError
          # This means Redis has probably exited.
          nil
        end
      end
    end
  end

  # Make the server a slave of another instance, or promote it as master.
  def slaveof(host, port)
    synchronize do |client|
      client.call([:slaveof, host, port])
    end
  end

  # Interact with the slowlog (get, len, reset)
  #
  # @param [String] subcommand e.g. `get`, `len`, `reset`
  # @param [Fixnum] length maximum number of entries to return
  # @return [Array<String>, Fixnum, String] depends on subcommand
  def slowlog(subcommand, length=nil)
    synchronize do |client|
      args = [:slowlog, subcommand]
      args << length if length
      client.call args
    end
  end

  # Internal command used for replication.
  def sync
    synchronize do |client|
      client.call([:sync])
    end
  end

  # Return the server time.
  #
  # @example
  #   r.time # => [ 1333093196, 606806 ]
  #
  # @return [Array<Fixnum>] tuple of seconds since UNIX epoch and
  #   microseconds in the current second
  def time
    synchronize do |client|
      client.call([:time]) do |reply|
        reply.map(&:to_i) if reply
      end
    end
  end

  # Remove the expiration from a key.
  #
  # @param [String] key
  # @return [Boolean] whether the timeout was removed or not
  def persist(key)
    synchronize do |client|
      client.call([:persist, key], &_boolify)
    end
  end

  # Set a key's time to live in seconds.
  #
  # @param [String] key
  # @param [Fixnum] seconds time to live
  # @return [Boolean] whether the timeout was set or not
  def expire(key, seconds)
    synchronize do |client|
      client.call([:expire, key, seconds], &_boolify)
    end
  end

  # Set the expiration for a key as a UNIX timestamp.
  #
  # @param [String] key
  # @param [Fixnum] unix_time expiry time specified as a UNIX timestamp
  # @return [Boolean] whether the timeout was set or not
  def expireat(key, unix_time)
    synchronize do |client|
      client.call([:expireat, key, unix_time], &_boolify)
    end
  end

  # Get the time to live (in seconds) for a key.
  #
  # @param [String] key
  # @return [Fixnum] remaining time to live in seconds, or -1 if the
  #   key does not exist or does not have a timeout
  def ttl(key)
    synchronize do |client|
      client.call([:ttl, key])
    end
  end

  # Set a key's time to live in milliseconds.
  #
  # @param [String] key
  # @param [Fixnum] milliseconds time to live
  # @return [Boolean] whether the timeout was set or not
  def pexpire(key, milliseconds)
    synchronize do |client|
      client.call([:pexpire, key, milliseconds], &_boolify)
    end
  end

  # Set the expiration for a key as number of milliseconds from UNIX Epoch.
  #
  # @param [String] key
  # @param [Fixnum] ms_unix_time expiry time specified as number of milliseconds from UNIX Epoch.
  # @return [Boolean] whether the timeout was set or not
  def pexpireat(key, ms_unix_time)
    synchronize do |client|
      client.call([:pexpireat, key, ms_unix_time], &_boolify)
    end
  end

  # Get the time to live (in milliseconds) for a key.
  #
  # @param [String] key
  # @return [Fixnum] remaining time to live in milliseconds, or -1 if the
  #   key does not exist or does not have a timeout
  def pttl(key)
    synchronize do |client|
      client.call([:pttl, key])
    end
  end

  # Return a serialized version of the value stored at a key.
  #
  # @param [String] key
  # @return [String] serialized_value
  def dump(key)
    synchronize do |client|
      client.call([:dump, key])
    end
  end

  # Create a key using the serialized value, previously obtained using DUMP.
  #
  # @param [String] key
  # @param [String] ttl
  # @param [String] serialized_value
  # @return `"OK"`
  def restore(key, ttl, serialized_value)
    synchronize do |client|
      client.call([:restore, key, ttl, serialized_value])
    end
  end

  # Delete one or more keys.
  #
  # @param [String, Array<String>] keys
  # @return [Fixnum] number of keys that were deleted
  def del(*keys)
    synchronize do |client|
      client.call([:del] + keys)
    end
  end

  # Determine if a key exists.
  #
  # @param [String] key
  # @return [Boolean]
  def exists(key)
    synchronize do |client|
      client.call([:exists, key], &_boolify)
    end
  end

  # Find all keys matching the given pattern.
  #
  # @param [String] pattern
  # @return [Array<String>]
  def keys(pattern = "*")
    synchronize do |client|
      client.call([:keys, pattern]) do |reply|
        if reply.kind_of?(String)
          reply.split(" ")
        else
          reply
        end
      end
    end
  end

  # Move a key to another database.
  #
  # @example Move a key to another database
  #   redis.set "foo", "bar"
  #     # => "OK"
  #   redis.move "foo", 2
  #     # => true
  #   redis.exists "foo"
  #     # => false
  #   redis.select 2
  #     # => "OK"
  #   redis.exists "foo"
  #     # => true
  #   resis.get "foo"
  #     # => "bar"
  #
  # @param [String] key
  # @param [Fixnum] db
  # @return [Boolean] whether the key was moved or not
  def move(key, db)
    synchronize do |client|
      client.call([:move, key, db], &_boolify)
    end
  end

  def object(*args)
    synchronize do |client|
      client.call([:object] + args)
    end
  end

  # Return a random key from the keyspace.
  #
  # @return [String]
  def randomkey
    synchronize do |client|
      client.call([:randomkey])
    end
  end

  # Rename a key. If the new key already exists it is overwritten.
  #
  # @param [String] old_name
  # @param [String] new_name
  # @return [String] `OK`
  def rename(old_name, new_name)
    synchronize do |client|
      client.call([:rename, old_name, new_name])
    end
  end

  # Rename a key, only if the new key does not exist.
  #
  # @param [String] old_name
  # @param [String] new_name
  # @return [Boolean] whether the key was renamed or not
  def renamenx(old_name, new_name)
    synchronize do |client|
      client.call([:renamenx, old_name, new_name], &_boolify)
    end
  end

  # Sort the elements in a list, set or sorted set.
  #
  # @example Retrieve the first 2 elements from an alphabetically sorted "list"
  #   redis.sort("list", :order => "alpha", :limit => [0, 2])
  #     # => ["a", "b"]
  # @example Store an alphabetically descending list in "target"
  #   redis.sort("list", :order => "desc alpha", :store => "target")
  #     # => 26
  #
  # @param [String] key
  # @param [Hash] options
  #   - `:by => String`: use external key to sort elements by
  #   - `:limit => [offset, count]`: skip `offset` elements, return a maximum
  #   of `count` elements
  #   - `:get => [String, Array<String>]`: single key or array of keys to
  #   retrieve per element in the result
  #   - `:order => String`: combination of `ASC`, `DESC` and optionally `ALPHA`
  #   - `:store => String`: key to store the result at
  #
  # @return [Array<String>, Array<Array<String>>, Fixnum]
  #   - when `:get` is not specified, or holds a single element, an array of elements
  #   - when `:get` is specified, and holds more than one element, an array of
  #   elements where every element is an array with the result for every
  #   element specified in `:get`
  #   - when `:store` is specified, the number of elements in the stored result
  def sort(key, options = {})
    args = []

    by = options[:by]
    args.concat(["BY", by]) if by

    limit = options[:limit]
    args.concat(["LIMIT"] + limit) if limit

    get = Array(options[:get])
    args.concat(["GET"].product(get).flatten) unless get.empty?

    order = options[:order]
    args.concat(order.split(" ")) if order

    store = options[:store]
    args.concat(["STORE", store]) if store

    synchronize do |client|
      client.call([:sort, key] + args) do |reply|
        if get.size > 1 && !store
          if reply
            reply.each_slice(get.size).to_a
          end
        else
          reply
        end
      end
    end
  end

  # Determine the type stored at key.
  #
  # @param [String] key
  # @return [String] `string`, `list`, `set`, `zset`, `hash` or `none`
  def type(key)
    synchronize do |client|
      client.call([:type, key])
    end
  end

  # Decrement the integer value of a key by one.
  #
  # @example
  #   redis.decr("value")
  #     # => 4
  #
  # @param [String] key
  # @return [Fixnum] value after decrementing it
  def decr(key)
    synchronize do |client|
      client.call([:decr, key])
    end
  end

  # Decrement the integer value of a key by the given number.
  #
  # @example
  #   redis.decrby("value", 5)
  #     # => 0
  #
  # @param [String] key
  # @param [Fixnum] decrement
  # @return [Fixnum] value after decrementing it
  def decrby(key, decrement)
    synchronize do |client|
      client.call([:decrby, key, decrement])
    end
  end

  # Increment the integer value of a key by one.
  #
  # @example
  #   redis.incr("value")
  #     # => 6
  #
  # @param [String] key
  # @return [Fixnum] value after incrementing it
  def incr(key)
    synchronize do |client|
      client.call([:incr, key])
    end
  end

  # Increment the integer value of a key by the given integer number.
  #
  # @example
  #   redis.incrby("value", 5)
  #     # => 10
  #
  # @param [String] key
  # @param [Fixnum] increment
  # @return [Fixnum] value after incrementing it
  def incrby(key, increment)
    synchronize do |client|
      client.call([:incrby, key, increment])
    end
  end

  # Increment the numeric value of a key by the given float number.
  #
  # @example
  #   redis.incrbyfloat("value", 1.23)
  #     # => 1.23
  #
  # @param [String] key
  # @param [Float] increment
  # @return [Float] value after incrementing it
  def incrbyfloat(key, increment)
    synchronize do |client|
      client.call([:incrbyfloat, key, increment]) do |reply|
        _floatify(reply) if reply
      end
    end
  end

  # Set the string value of a key.
  #
  # @param [String] key
  # @param [String] value
  # @return `"OK"`
  def set(key, value)
    synchronize do |client|
      client.call([:set, key, value.to_s])
    end
  end

  alias :[]= :set

  # Set the time to live in seconds of a key.
  #
  # @param [String] key
  # @param [Fixnum] ttl
  # @param [String] value
  # @return `"OK"`
  def setex(key, ttl, value)
    synchronize do |client|
      client.call([:setex, key, ttl, value.to_s])
    end
  end

  # Set the time to live in milliseconds of a key.
  #
  # @param [String] key
  # @param [Fixnum] ttl
  # @param [String] value
  # @return `"OK"`
  def psetex(key, ttl, value)
    synchronize do |client|
      client.call([:psetex, key, ttl, value.to_s])
    end
  end

  # Set the value of a key, only if the key does not exist.
  #
  # @param [String] key
  # @param [String] value
  # @return [Boolean] whether the key was set or not
  def setnx(key, value)
    synchronize do |client|
      client.call([:setnx, key, value.to_s], &_boolify)
    end
  end

  # Set one or more values.
  #
  # @example
  #   redis.mset("key1", "v1", "key2", "v2")
  #     # => "OK"
  #
  # @param [Array<String>] args array of keys and values
  # @return `"OK"`
  #
  # @see #mapped_mset
  def mset(*args)
    synchronize do |client|
      client.call([:mset] + args)
    end
  end

  # Set one or more values.
  #
  # @example
  #   redis.mapped_mset({ "f1" => "v1", "f2" => "v2" })
  #     # => "OK"
  #
  # @param [Hash] hash keys mapping to values
  # @return `"OK"`
  #
  # @see #mset
  def mapped_mset(hash)
    mset(hash.to_a.flatten)
  end

  # Set one or more values, only if none of the keys exist.
  #
  # @example
  #   redis.msetnx("key1", "v1", "key2", "v2")
  #     # => true
  #
  # @param [Array<String>] args array of keys and values
  # @return [Boolean] whether or not all values were set
  #
  # @see #mapped_msetnx
  def msetnx(*args)
    synchronize do |client|
      client.call([:msetnx] + args, &_boolify)
    end
  end

  # Set one or more values, only if none of the keys exist.
  #
  # @example
  #   redis.msetnx({ "key1" => "v1", "key2" => "v2" })
  #     # => true
  #
  # @param [Hash] hash keys mapping to values
  # @return [Boolean] whether or not all values were set
  #
  # @see #msetnx
  def mapped_msetnx(hash)
    msetnx(hash.to_a.flatten)
  end

  # Get the value of a key.
  #
  # @param [String] key
  # @return [String]
  def get(key)
    synchronize do |client|
      client.call([:get, key])
    end
  end

  alias :[] :get

  # Get the values of all the given keys.
  #
  # @example
  #   redis.mget("key1", "key1")
  #     # => ["v1", "v2"]
  #
  # @param [Array<String>] keys
  # @return [Array<String>] an array of values for the specified keys
  #
  # @see #mapped_mget
  def mget(*keys, &blk)
    synchronize do |client|
      client.call([:mget] + keys, &blk)
    end
  end

  # Get the values of all the given keys.
  #
  # @example
  #   redis.mapped_mget("key1", "key1")
  #     # => { "key1" => "v1", "key2" => "v2" }
  #
  # @param [Array<String>] keys array of keys
  # @return [Hash] a hash mapping the specified keys to their values
  #
  # @see #mget
  def mapped_mget(*keys)
    mget(*keys) do |reply|
      if reply.kind_of?(Array)
        Hash[keys.zip(reply)]
      else
        reply
      end
    end
  end

  # Overwrite part of a string at key starting at the specified offset.
  #
  # @param [String] key
  # @param [Fixnum] offset byte offset
  # @param [String] value
  # @return [Fixnum] length of the string after it was modified
  def setrange(key, offset, value)
    synchronize do |client|
      client.call([:setrange, key, offset, value.to_s])
    end
  end

  # Get a substring of the string stored at a key.
  #
  # @param [String] key
  # @param [Fixnum] start zero-based start offset
  # @param [Fixnum] stop zero-based end offset. Use -1 for representing
  #   the end of the string
  # @return [Fixnum] `0` or `1`
  def getrange(key, start, stop)
    synchronize do |client|
      client.call([:getrange, key, start, stop])
    end
  end

  # Sets or clears the bit at offset in the string value stored at key.
  #
  # @param [String] key
  # @param [Fixnum] offset bit offset
  # @param [Fixnum] value bit value `0` or `1`
  # @return [Fixnum] the original bit value stored at `offset`
  def setbit(key, offset, value)
    synchronize do |client|
      client.call([:setbit, key, offset, value])
    end
  end

  # Returns the bit value at offset in the string value stored at key.
  #
  # @param [String] key
  # @param [Fixnum] offset bit offset
  # @return [Fixnum] `0` or `1`
  def getbit(key, offset)
    synchronize do |client|
      client.call([:getbit, key, offset])
    end
  end

  # Append a value to a key.
  #
  # @param [String] key
  # @param [String] value value to append
  # @return [Fixnum] length of the string after appending
  def append(key, value)
    synchronize do |client|
      client.call([:append, key, value])
    end
  end

  # Count the number of set bits in a range of the string value stored at key.
  #
  # @param [String] key
  # @param [Fixnum] start start index
  # @param [Fixnum] stop stop index
  # @return [Fixnum] the number of bits set to 1
  def bitcount(key, start = 0, stop = -1)
    synchronize do |client|
      client.call([:bitcount, key, start, stop])
    end
  end

  # Perform a bitwise operation between strings and store the resulting string in a key.
  #
  # @param [String] operation e.g. `and`, `or`, `xor`, `not`
  # @param [String] destkey destination key
  # @param [String, Array<String>] keys one or more source keys to perform `operation`
  # @return [Fixnum] the length of the string stored in `destkey`
  def bitop(operation, destkey, *keys)
    synchronize do |client|
      client.call([:bitop, operation, destkey] + keys)
    end
  end

  # Set the string value of a key and return its old value.
  #
  # @param [String] key
  # @param [String] value value to replace the current value with
  # @return [String] the old value stored in the key, or `nil` if the key
  #   did not exist
  def getset(key, value)
    synchronize do |client|
      client.call([:getset, key, value.to_s])
    end
  end

  # Get the length of the value stored in a key.
  #
  # @param [String] key
  # @return [Fixnum] the length of the value stored in the key, or 0
  #   if the key does not exist
  def strlen(key)
    synchronize do |client|
      client.call([:strlen, key])
    end
  end

  # Get the length of a list.
  #
  # @param [String] key
  # @return [Fixnum]
  def llen(key)
    synchronize do |client|
      client.call([:llen, key])
    end
  end

  # Prepend one or more values to a list, creating the list if it doesn't exist
  #
  # @param [String] key
  # @param [String, Array] string value, or array of string values to push
  # @return [Fixnum] the length of the list after the push operation
  def lpush(key, value)
    synchronize do |client|
      client.call([:lpush, key, value])
    end
  end

  # Prepend a value to a list, only if the list exists.
  #
  # @param [String] key
  # @param [String] value
  # @return [Fixnum] the length of the list after the push operation
  def lpushx(key, value)
    synchronize do |client|
      client.call([:lpushx, key, value])
    end
  end

  # Append one or more values to a list, creating the list if it doesn't exist
  #
  # @param [String] key
  # @param [String] value
  # @return [Fixnum] the length of the list after the push operation
  def rpush(key, value)
    synchronize do |client|
      client.call([:rpush, key, value])
    end
  end

  # Append a value to a list, only if the list exists.
  #
  # @param [String] key
  # @param [String] value
  # @return [Fixnum] the length of the list after the push operation
  def rpushx(key, value)
    synchronize do |client|
      client.call([:rpushx, key, value])
    end
  end

  # Remove and get the first element in a list.
  #
  # @param [String] key
  # @return [String]
  def lpop(key)
    synchronize do |client|
      client.call([:lpop, key])
    end
  end

  # Remove and get the last element in a list.
  #
  # @param [String] key
  # @return [String]
  def rpop(key)
    synchronize do |client|
      client.call([:rpop, key])
    end
  end

  # Remove the last element in a list, append it to another list and return it.
  #
  # @param [String] source source key
  # @param [String] destination destination key
  # @return [nil, String] the element, or nil when the source key does not exist
  def rpoplpush(source, destination)
    synchronize do |client|
      client.call([:rpoplpush, source, destination])
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
    timeout = options[:timeout] || 0

    synchronize do |client|
      command = [cmd, keys, timeout]
      timeout += client.timeout if timeout > 0
      client.call_with_timeout(command, timeout)
    end
  end

  # Remove and get the first element in a list, or block until one is available.
  #
  # @example With timeout
  #   list, element = redis.blpop("list", :timeout => 5)
  #     # => nil on timeout
  #     # => ["list", "element"] on success
  # @example Without timeout
  #   list, element = redis.blpop("list")
  #     # => ["list", "element"]
  # @example Blocking pop on multiple lists
  #   list, element = redis.blpop(["list", "another_list"])
  #     # => ["list", "element"]
  #
  # @param [String, Array<String>] keys one or more keys to perform the
  #   blocking pop on
  # @param [Hash] options
  #   - `:timeout => Fixnum`: timeout in seconds, defaults to no timeout
  #
  # @return [nil, [String, String]]
  #   - `nil` when the operation timed out
  #   - tuple of the list that was popped from and element was popped otherwise
  def blpop(*args)
    _bpop(:blpop, args)
  end

  # Remove and get the last element in a list, or block until one is available.
  #
  # @param [String, Array<String>] keys one or more keys to perform the
  #   blocking pop on
  # @param [Hash] options
  #   - `:timeout => Fixnum`: timeout in seconds, defaults to no timeout
  #
  # @return [nil, [String, String]]
  #   - `nil` when the operation timed out
  #   - tuple of the list that was popped from and element was popped otherwise
  #
  # @see #blpop
  def brpop(*args)
    _bpop(:brpop, args)
  end

  # Pop a value from a list, push it to another list and return it; or block
  # until one is available.
  #
  # @param [String] source source key
  # @param [String] destination destination key
  # @param [Hash] options
  #   - `:timeout => Fixnum`: timeout in seconds, defaults to no timeout
  #
  # @return [nil, String]
  #   - `nil` when the operation timed out
  #   - the element was popped and pushed otherwise
  def brpoplpush(source, destination, options = {})
    case options
    when Integer
      # Issue deprecation notice in obnoxious mode...
      options = { :timeout => options }
    end

    timeout = options[:timeout] || 0

    synchronize do |client|
      command = [:brpoplpush, source, destination, timeout]
      timeout += client.timeout if timeout > 0
      client.call_with_timeout(command, timeout)
    end
  end

  # Get an element from a list by its index.
  #
  # @param [String] key
  # @param [Fixnum] index
  # @return [String]
  def lindex(key, index)
    synchronize do |client|
      client.call([:lindex, key, index])
    end
  end

  # Insert an element before or after another element in a list.
  #
  # @param [String] key
  # @param [String, Symbol] where `BEFORE` or `AFTER`
  # @param [String] pivot reference element
  # @param [String] value
  # @return [Fixnum] length of the list after the insert operation, or `-1`
  #   when the element `pivot` was not found
  def linsert(key, where, pivot, value)
    synchronize do |client|
      client.call([:linsert, key, where, pivot, value])
    end
  end

  # Get a range of elements from a list.
  #
  # @param [String] key
  # @param [Fixnum] start start index
  # @param [Fixnum] stop stop index
  # @return [Array<String>]
  def lrange(key, start, stop)
    synchronize do |client|
      client.call([:lrange, key, start, stop])
    end
  end

  # Remove elements from a list.
  #
  # @param [String] key
  # @param [Fixnum] count number of elements to remove. Use a positive
  #   value to remove the first `count` occurrences of `value`. A negative
  #   value to remove the last `count` occurrences of `value`. Or zero, to
  #   remove all occurrences of `value` from the list.
  # @param [String] value
  # @return [Fixnum] the number of removed elements
  def lrem(key, count, value)
    synchronize do |client|
      client.call([:lrem, key, count, value])
    end
  end

  # Set the value of an element in a list by its index.
  #
  # @param [String] key
  # @param [Fixnum] index
  # @param [String] value
  # @return [String] `OK`
  def lset(key, index, value)
    synchronize do |client|
      client.call([:lset, key, index, value])
    end
  end

  # Trim a list to the specified range.
  #
  # @param [String] key
  # @param [Fixnum] start start index
  # @param [Fixnum] stop stop index
  # @return [String] `OK`
  def ltrim(key, start, stop)
    synchronize do |client|
      client.call([:ltrim, key, start, stop])
    end
  end

  # Get the number of members in a set.
  #
  # @param [String] key
  # @return [Fixnum]
  def scard(key)
    synchronize do |client|
      client.call([:scard, key])
    end
  end

  # Add one or more members to a set.
  #
  # @param [String] key
  # @param [String, Array<String>] member one member, or array of members
  # @return [Boolean, Fixnum] `Boolean` when a single member is specified,
  #   holding whether or not adding the member succeeded, or `Fixnum` when an
  #   array of members is specified, holding the number of members that were
  #   successfully added
  def sadd(key, member)
    synchronize do |client|
      client.call([:sadd, key, member]) do |reply|
        if member.is_a? Array
          # Variadic: return integer
          reply
        else
          # Single argument: return boolean
          _boolify.call(reply)
        end
      end
    end
  end

  # Remove one or more members from a set.
  #
  # @param [String] key
  # @param [String, Array<String>] member one member, or array of members
  # @return [Boolean, Fixnum] `Boolean` when a single member is specified,
  #   holding whether or not removing the member succeeded, or `Fixnum` when an
  #   array of members is specified, holding the number of members that were
  #   successfully removed
  def srem(key, member)
    synchronize do |client|
      client.call([:srem, key, member]) do |reply|
        if member.is_a? Array
          # Variadic: return integer
          reply
        else
          # Single argument: return boolean
          _boolify.call(reply)
        end
      end
    end
  end

  # Remove and return a random member from a set.
  #
  # @param [String] key
  # @return [String]
  def spop(key)
    synchronize do |client|
      client.call([:spop, key])
    end
  end

  # Get one or more random members from a set.
  #
  # @param [String] key
  # @param [Fixnum] count
  # @return [String]
  def srandmember(key, count = nil)
    synchronize do |client|
      if count.nil?
        client.call([:srandmember, key])
      else
        client.call([:srandmember, key, count])
      end
    end
  end

  # Move a member from one set to another.
  #
  # @param [String] source source key
  # @param [String] destination destination key
  # @param [String] member member to move from `source` to `destination`
  # @return [Boolean]
  def smove(source, destination, member)
    synchronize do |client|
      client.call([:smove, source, destination, member], &_boolify)
    end
  end

  # Determine if a given value is a member of a set.
  #
  # @param [String] key
  # @param [String] member
  # @return [Boolean]
  def sismember(key, member)
    synchronize do |client|
      client.call([:sismember, key, member], &_boolify)
    end
  end

  # Get all the members in a set.
  #
  # @param [String] key
  # @return [Array<String>]
  def smembers(key)
    synchronize do |client|
      client.call([:smembers, key])
    end
  end

  # Subtract multiple sets.
  #
  # @param [String, Array<String>] keys keys pointing to sets to subtract
  # @return [Array<String>] members in the difference
  def sdiff(*keys)
    synchronize do |client|
      client.call([:sdiff] + keys)
    end
  end

  # Subtract multiple sets and store the resulting set in a key.
  #
  # @param [String] destination destination key
  # @param [String, Array<String>] keys keys pointing to sets to subtract
  # @return [Fixnum] number of elements in the resulting set
  def sdiffstore(destination, *keys)
    synchronize do |client|
      client.call([:sdiffstore, destination] + keys)
    end
  end

  # Intersect multiple sets.
  #
  # @param [String, Array<String>] keys keys pointing to sets to intersect
  # @return [Array<String>] members in the intersection
  def sinter(*keys)
    synchronize do |client|
      client.call([:sinter] + keys)
    end
  end

  # Intersect multiple sets and store the resulting set in a key.
  #
  # @param [String] destination destination key
  # @param [String, Array<String>] keys keys pointing to sets to intersect
  # @return [Fixnum] number of elements in the resulting set
  def sinterstore(destination, *keys)
    synchronize do |client|
      client.call([:sinterstore, destination] + keys)
    end
  end

  # Add multiple sets.
  #
  # @param [String, Array<String>] keys keys pointing to sets to unify
  # @return [Array<String>] members in the union
  def sunion(*keys)
    synchronize do |client|
      client.call([:sunion] + keys)
    end
  end

  # Add multiple sets and store the resulting set in a key.
  #
  # @param [String] destination destination key
  # @param [String, Array<String>] keys keys pointing to sets to unify
  # @return [Fixnum] number of elements in the resulting set
  def sunionstore(destination, *keys)
    synchronize do |client|
      client.call([:sunionstore, destination] + keys)
    end
  end

  # Get the number of members in a sorted set.
  #
  # @example
  #   redis.zcard("zset")
  #     # => 4
  #
  # @param [String] key
  # @return [Fixnum]
  def zcard(key)
    synchronize do |client|
      client.call([:zcard, key])
    end
  end

  # Add one or more members to a sorted set, or update the score for members
  # that already exist.
  #
  # @example Add a single `[score, member]` pair to a sorted set
  #   redis.zadd("zset", 32.0, "member")
  # @example Add an array of `[score, member]` pairs to a sorted set
  #   redis.zadd("zset", [[32.0, "a"], [64.0, "b"]])
  #
  # @param [String] key
  # @param [[Float, String], Array<[Float, String]>] args
  #   - a single `[score, member]` pair
  #   - an array of `[score, member]` pairs
  #
  # @return [Boolean, Fixnum]
  #   - `Boolean` when a single pair is specified, holding whether or not it was
  #   **added** to the sorted set
  #   - `Fixnum` when an array of pairs is specified, holding the number of
  #   pairs that were **added** to the sorted set
  def zadd(key, *args)
    synchronize do |client|
      if args.size == 1 && args[0].is_a?(Array)
        # Variadic: return integer
        client.call([:zadd, key] + args[0])
      elsif args.size == 2
        # Single pair: return boolean
        client.call([:zadd, key, args[0], args[1]], &_boolify)
      else
        raise ArgumentError, "wrong number of arguments"
      end
    end
  end

  # Increment the score of a member in a sorted set.
  #
  # @example
  #   redis.zincrby("zset", 32.0, "a")
  #     # => 64.0
  #
  # @param [String] key
  # @param [Float] increment
  # @param [String] member
  # @return [Float] score of the member after incrementing it
  def zincrby(key, increment, member)
    synchronize do |client|
      client.call([:zincrby, key, increment, member]) do |reply|
        _floatify(reply) if reply
      end
    end
  end

  # Remove one or more members from a sorted set.
  #
  # @example Remove a single member from a sorted set
  #   redis.zrem("zset", "a")
  # @example Remove an array of members from a sorted set
  #   redis.zrem("zset", ["a", "b"])
  #
  # @param [String] key
  # @param [String, Array<String>] member
  #   - a single member
  #   - an array of members
  #
  # @return [Boolean, Fixnum]
  #   - `Boolean` when a single member is specified, holding whether or not it
  #   was removed from the sorted set
  #   - `Fixnum` when an array of pairs is specified, holding the number of
  #   members that were removed to the sorted set
  def zrem(key, member)
    synchronize do |client|
      client.call([:zrem, key, member]) do |reply|
        if member.is_a? Array
          # Variadic: return integer
          reply
        else
          # Single argument: return boolean
          _boolify.call(reply)
        end
      end
    end
  end

  # Get the score associated with the given member in a sorted set.
  #
  # @example Get the score for member "a"
  #   redis.zscore("zset", "a")
  #     # => 32.0
  #
  # @param [String] key
  # @param [String] member
  # @return [Float] score of the member
  def zscore(key, member)
    synchronize do |client|
      client.call([:zscore, key, member]) do |reply|
        _floatify(reply) if reply
      end
    end
  end

  # Return a range of members in a sorted set, by index.
  #
  # @example Retrieve all members from a sorted set
  #   redis.zrange("zset", 0, -1)
  #     # => ["a", "b"]
  # @example Retrieve all members and their scores from a sorted set
  #   redis.zrange("zset", 0, -1, :with_scores => true)
  #     # => [["a", 32.0], ["b", 64.0]]
  #
  # @param [String] key
  # @param [Fixnum] start start index
  # @param [Fixnum] stop stop index
  # @param [Hash] options
  #   - `:with_scores => true`: include scores in output
  #
  # @return [Array<String>, Array<[String, Float]>]
  #   - when `:with_scores` is not specified, an array of members
  #   - when `:with_scores` is specified, an array with `[member, score]` pairs
  def zrange(key, start, stop, options = {})
    args = []

    with_scores = options[:with_scores] || options[:withscores]
    args << "WITHSCORES" if with_scores

    synchronize do |client|
      client.call([:zrange, key, start, stop] + args) do |reply|
        if with_scores
          if reply
            reply.each_slice(2).map do |member, score|
              [member, _floatify(score)]
            end
          end
        else
          reply
        end
      end
    end
  end

  # Return a range of members in a sorted set, by index, with scores ordered
  # from high to low.
  #
  # @example Retrieve all members from a sorted set
  #   redis.zrevrange("zset", 0, -1)
  #     # => ["b", "a"]
  # @example Retrieve all members and their scores from a sorted set
  #   redis.zrevrange("zset", 0, -1, :with_scores => true)
  #     # => [["b", 64.0], ["a", 32.0]]
  #
  # @see #zrange
  def zrevrange(key, start, stop, options = {})
    args = []

    with_scores = options[:with_scores] || options[:withscores]
    args << "WITHSCORES" if with_scores

    synchronize do |client|
      client.call([:zrevrange, key, start, stop] + args) do |reply|
        if with_scores
          if reply
            reply.each_slice(2).map do |member, score|
              [member, _floatify(score)]
            end
          end
        else
          reply
        end
      end
    end
  end

  # Determine the index of a member in a sorted set.
  #
  # @param [String] key
  # @param [String] member
  # @return [Fixnum]
  def zrank(key, member)
    synchronize do |client|
      client.call([:zrank, key, member])
    end
  end

  # Determine the index of a member in a sorted set, with scores ordered from
  # high to low.
  #
  # @param [String] key
  # @param [String] member
  # @return [Fixnum]
  def zrevrank(key, member)
    synchronize do |client|
      client.call([:zrevrank, key, member])
    end
  end

  # Remove all members in a sorted set within the given indexes.
  #
  # @example Remove first 5 members
  #   redis.zremrangebyrank("zset", 0, 4)
  #     # => 5
  # @example Remove last 5 members
  #   redis.zremrangebyrank("zset", -5, -1)
  #     # => 5
  #
  # @param [String] key
  # @param [Fixnum] start start index
  # @param [Fixnum] stop stop index
  # @return [Fixnum] number of members that were removed
  def zremrangebyrank(key, start, stop)
    synchronize do |client|
      client.call([:zremrangebyrank, key, start, stop])
    end
  end

  # Return a range of members in a sorted set, by score.
  #
  # @example Retrieve members with score `>= 5` and `< 100`
  #   redis.zrangebyscore("zset", "5", "(100")
  #     # => ["a", "b"]
  # @example Retrieve the first 2 members with score `>= 0`
  #   redis.zrangebyscore("zset", "0", "+inf", :limit => [0, 2])
  #     # => ["a", "b"]
  # @example Retrieve members and their scores with scores `> 5`
  #   redis.zrangebyscore("zset", "(5", "+inf", :with_scores => true)
  #     # => [["a", 32.0], ["b", 64.0]]
  #
  # @param [String] key
  # @param [String] min
  #   - inclusive minimum score is specified verbatim
  #   - exclusive minimum score is specified by prefixing `(`
  # @param [String] max
  #   - inclusive maximum score is specified verbatim
  #   - exclusive maximum score is specified by prefixing `(`
  # @param [Hash] options
  #   - `:with_scores => true`: include scores in output
  #   - `:limit => [offset, count]`: skip `offset` members, return a maximum of
  #   `count` members
  #
  # @return [Array<String>, Array<[String, Float]>]
  #   - when `:with_scores` is not specified, an array of members
  #   - when `:with_scores` is specified, an array with `[member, score]` pairs
  def zrangebyscore(key, min, max, options = {})
    args = []

    with_scores = options[:with_scores] || options[:withscores]
    args.concat(["WITHSCORES"]) if with_scores

    limit = options[:limit]
    args.concat(["LIMIT"] + limit) if limit

    synchronize do |client|
      client.call([:zrangebyscore, key, min, max] + args) do |reply|
        if with_scores
          if reply
            reply.each_slice(2).map do |member, score|
              [member, _floatify(score)]
            end
          end
        else
          reply
        end
      end
    end
  end

  # Return a range of members in a sorted set, by score, with scores ordered
  # from high to low.
  #
  # @example Retrieve members with score `< 100` and `>= 5`
  #   redis.zrevrangebyscore("zset", "(100", "5")
  #     # => ["b", "a"]
  # @example Retrieve the first 2 members with score `<= 0`
  #   redis.zrevrangebyscore("zset", "0", "-inf", :limit => [0, 2])
  #     # => ["b", "a"]
  # @example Retrieve members and their scores with scores `> 5`
  #   redis.zrevrangebyscore("zset", "+inf", "(5", :with_scores => true)
  #     # => [["b", 64.0], ["a", 32.0]]
  #
  # @see #zrangebyscore
  def zrevrangebyscore(key, max, min, options = {})
    args = []

    with_scores = options[:with_scores] || options[:withscores]
    args.concat(["WITHSCORES"]) if with_scores

    limit = options[:limit]
    args.concat(["LIMIT"] + limit) if limit

    synchronize do |client|
      client.call([:zrevrangebyscore, key, max, min] + args) do |reply|
        if with_scores
          if reply
            reply.each_slice(2).map do |member, score|
              [member, _floatify(score)]
            end
          end
        else
          reply
        end
      end
    end
  end

  # Remove all members in a sorted set within the given scores.
  #
  # @example Remove members with score `>= 5` and `< 100`
  #   redis.zremrangebyscore("zset", "5", "(100")
  #     # => 2
  # @example Remove members with scores `> 5`
  #   redis.zremrangebyscore("zset", "(5", "+inf")
  #     # => 2
  #
  # @param [String] key
  # @param [String] min
  #   - inclusive minimum score is specified verbatim
  #   - exclusive minimum score is specified by prefixing `(`
  # @param [String] max
  #   - inclusive maximum score is specified verbatim
  #   - exclusive maximum score is specified by prefixing `(`
  # @return [Fixnum] number of members that were removed
  def zremrangebyscore(key, min, max)
    synchronize do |client|
      client.call([:zremrangebyscore, key, min, max])
    end
  end

  # Count the members in a sorted set with scores within the given values.
  #
  # @example Count members with score `>= 5` and `< 100`
  #   redis.zcount("zset", "5", "(100")
  #     # => 2
  # @example Count members with scores `> 5`
  #   redis.zcount("zset", "(5", "+inf")
  #     # => 2
  #
  # @param [String] key
  # @param [String] min
  #   - inclusive minimum score is specified verbatim
  #   - exclusive minimum score is specified by prefixing `(`
  # @param [String] max
  #   - inclusive maximum score is specified verbatim
  #   - exclusive maximum score is specified by prefixing `(`
  # @return [Fixnum] number of members in within the specified range
  def zcount(key, min, max)
    synchronize do |client|
      client.call([:zcount, key, min, max])
    end
  end

  # Intersect multiple sorted sets and store the resulting sorted set in a new
  # key.
  #
  # @example Compute the intersection of `2*zsetA` with `1*zsetB`, summing their scores
  #   redis.zinterstore("zsetC", ["zsetA", "zsetB"], :weights => [2.0, 1.0], :aggregate => "sum")
  #     # => 4
  #
  # @param [String] destination destination key
  # @param [Array<String>] keys source keys
  # @param [Hash] options
  #   - `:weights => [Float, Float, ...]`: weights to associate with source
  #   sorted sets
  #   - `:aggregate => String`: aggregate function to use (sum, min, max, ...)
  # @return [Fixnum] number of elements in the resulting sorted set
  def zinterstore(destination, keys, options = {})
    args = []

    weights = options[:weights]
    args.concat(["WEIGHTS"] + weights) if weights

    aggregate = options[:aggregate]
    args.concat(["AGGREGATE", aggregate]) if aggregate

    synchronize do |client|
      client.call([:zinterstore, destination, keys.size] + keys + args)
    end
  end

  # Add multiple sorted sets and store the resulting sorted set in a new key.
  #
  # @example Compute the union of `2*zsetA` with `1*zsetB`, summing their scores
  #   redis.zunionstore("zsetC", ["zsetA", "zsetB"], :weights => [2.0, 1.0], :aggregate => "sum")
  #     # => 8
  #
  # @param [String] destination destination key
  # @param [Array<String>] keys source keys
  # @param [Hash] options
  #   - `:weights => [Float, Float, ...]`: weights to associate with source
  #   sorted sets
  #   - `:aggregate => String`: aggregate function to use (sum, min, max, ...)
  # @return [Fixnum] number of elements in the resulting sorted set
  def zunionstore(destination, keys, options = {})
    args = []

    weights = options[:weights]
    args.concat(["WEIGHTS"] + weights) if weights

    aggregate = options[:aggregate]
    args.concat(["AGGREGATE", aggregate]) if aggregate

    synchronize do |client|
      client.call([:zunionstore, destination, keys.size] + keys + args)
    end
  end

  # Get the number of fields in a hash.
  #
  # @param [String] key
  # @return [Fixnum] number of fields in the hash
  def hlen(key)
    synchronize do |client|
      client.call([:hlen, key])
    end
  end

  # Set the string value of a hash field.
  #
  # @param [String] key
  # @param [String] field
  # @param [String] value
  # @return [Boolean] whether or not the field was **added** to the hash
  def hset(key, field, value)
    synchronize do |client|
      client.call([:hset, key, field, value], &_boolify)
    end
  end

  # Set the value of a hash field, only if the field does not exist.
  #
  # @param [String] key
  # @param [String] field
  # @param [String] value
  # @return [Boolean] whether or not the field was **added** to the hash
  def hsetnx(key, field, value)
    synchronize do |client|
      client.call([:hsetnx, key, field, value], &_boolify)
    end
  end

  # Set one or more hash values.
  #
  # @example
  #   redis.hmset("hash", "f1", "v1", "f2", "v2")
  #     # => "OK"
  #
  # @param [String] key
  # @param [Array<String>] attrs array of fields and values
  # @return `"OK"`
  #
  # @see #mapped_hmset
  def hmset(key, *attrs)
    synchronize do |client|
      client.call([:hmset, key] + attrs)
    end
  end

  # Set one or more hash values.
  #
  # @example
  #   redis.mapped_hmset("hash", { "f1" => "v1", "f2" => "v2" })
  #     # => "OK"
  #
  # @param [String] key
  # @param [Hash] hash fields mapping to values
  # @return `"OK"`
  #
  # @see #hmset
  def mapped_hmset(key, hash)
    hmset(key, hash.to_a.flatten)
  end

  # Get the value of a hash field.
  #
  # @param [String] key
  # @param [String] field
  # @return [String]
  def hget(key, field)
    synchronize do |client|
      client.call([:hget, key, field])
    end
  end

  # Get the values of all the given hash fields.
  #
  # @example
  #   redis.hmget("hash", "f1", "f2")
  #     # => ["v1", "v2"]
  #
  # @param [String] key
  # @param [Array<String>] fields array of fields
  # @return [Array<String>] an array of values for the specified fields
  #
  # @see #mapped_hmget
  def hmget(key, *fields, &blk)
    synchronize do |client|
      client.call([:hmget, key] + fields, &blk)
    end
  end

  # Get the values of all the given hash fields.
  #
  # @example
  #   redis.hmget("hash", "f1", "f2")
  #     # => { "f1" => "v1", "f2" => "v2" }
  #
  # @param [String] key
  # @param [Array<String>] fields array of fields
  # @return [Hash] a hash mapping the specified fields to their values
  #
  # @see #hmget
  def mapped_hmget(key, *fields)
    hmget(key, *fields) do |reply|
      if reply.kind_of?(Array)
        Hash[fields.zip(reply)]
      else
        reply
      end
    end
  end

  # Delete one or more hash fields.
  #
  # @param [String] key
  # @param [String, Array<String>] field
  # @return [Fixnum] the number of fields that were removed from the hash
  def hdel(key, field)
    synchronize do |client|
      client.call([:hdel, key, field])
    end
  end

  # Determine if a hash field exists.
  #
  # @param [String] key
  # @param [String] field
  # @return [Boolean] whether or not the field exists in the hash
  def hexists(key, field)
    synchronize do |client|
      client.call([:hexists, key, field], &_boolify)
    end
  end

  # Increment the integer value of a hash field by the given integer number.
  #
  # @param [String] key
  # @param [String] field
  # @param [Fixnum] increment
  # @return [Fixnum] value of the field after incrementing it
  def hincrby(key, field, increment)
    synchronize do |client|
      client.call([:hincrby, key, field, increment])
    end
  end

  # Increment the numeric value of a hash field by the given float number.
  #
  # @param [String] key
  # @param [String] field
  # @param [Float] increment
  # @return [Float] value of the field after incrementing it
  def hincrbyfloat(key, field, increment)
    synchronize do |client|
      client.call([:hincrbyfloat, key, field, increment]) do |reply|
        _floatify(reply) if reply
      end
    end
  end

  # Get all the fields in a hash.
  #
  # @param [String] key
  # @return [Array<String>]
  def hkeys(key)
    synchronize do |client|
      client.call([:hkeys, key])
    end
  end

  # Get all the values in a hash.
  #
  # @param [String] key
  # @return [Array<String>]
  def hvals(key)
    synchronize do |client|
      client.call([:hvals, key])
    end
  end

  # Get all the fields and values in a hash.
  #
  # @param [String] key
  # @return [Hash<String, String>]
  def hgetall(key)
    synchronize do |client|
      client.call([:hgetall, key], &_hashify)
    end
  end

  # Post a message to a channel.
  def publish(channel, message)
    synchronize do |client|
      client.call([:publish, channel, message])
    end
  end

  def subscribed?
    synchronize do |client|
      client.kind_of? SubscribedClient
    end
  end

  # Listen for messages published to the given channels.
  def subscribe(*channels, &block)
    synchronize do |client|
      _subscription(:subscribe, channels, block)
    end
  end

  # Stop listening for messages posted to the given channels.
  def unsubscribe(*channels)
    synchronize do |client|
      raise RuntimeError, "Can't unsubscribe if not subscribed." unless subscribed?
      client.unsubscribe(*channels)
    end
  end

  # Listen for messages published to channels matching the given patterns.
  def psubscribe(*channels, &block)
    synchronize do |client|
      _subscription(:psubscribe, channels, block)
    end
  end

  # Stop listening for messages posted to channels matching the given patterns.
  def punsubscribe(*channels)
    synchronize do |client|
      raise RuntimeError, "Can't unsubscribe if not subscribed." unless subscribed?
      client.punsubscribe(*channels)
    end
  end

  # Watch the given keys to determine execution of the MULTI/EXEC block.
  #
  # Using a block is optional, but is necessary for thread-safety.
  #
  # An `#unwatch` is automatically issued if an exception is raised within the
  # block that is a subclass of StandardError and is not a ConnectionError.
  #
  # @example With a block
  #   redis.watch("key") do
  #     if redis.get("key") == "some value"
  #       redis.multi do |multi|
  #         multi.set("key", "other value")
  #         multi.incr("counter")
  #       end
  #     else
  #       redis.unwatch
  #     end
  #   end
  #     # => ["OK", 6]
  #
  # @example Without a block
  #   redis.watch("key")
  #     # => "OK"
  #
  # @param [String, Array<String>] keys one or more keys to watch
  # @return [Object] if using a block, returns the return value of the block
  # @return [String] if not using a block, returns `OK`
  #
  # @see #unwatch
  # @see #multi
  def watch(*keys)
    synchronize do |client|
      client.call([:watch] + keys)

      if block_given?
        begin
          yield(self)
        rescue ConnectionError
          raise
        rescue StandardError
          unwatch
          raise
        end
      end
    end
  end

  # Forget about all watched keys.
  #
  # @return [String] `OK`
  #
  # @see #watch
  # @see #multi
  def unwatch
    synchronize do |client|
      client.call([:unwatch])
    end
  end

  def pipelined
    synchronize do |client|
      begin
        original, @client = @client, Pipeline.new
        yield(self)
        original.call_pipeline(@client)
      ensure
        @client = original
      end
    end
  end

  # Mark the start of a transaction block.
  #
  # Passing a block is optional.
  #
  # @example With a block
  #   redis.multi do |multi|
  #     multi.set("key", "value")
  #     multi.incr("counter")
  #   end # => ["OK", 6]
  #
  # @example Without a block
  #   redis.multi
  #     # => "OK"
  #   redis.set("key", "value")
  #     # => "QUEUED"
  #   redis.incr("counter")
  #     # => "QUEUED"
  #   redis.exec
  #     # => ["OK", 6]
  #
  # @yield [multi] the commands that are called inside this block are cached
  #   and written to the server upon returning from it
  # @yieldparam [Redis] multi `self`
  #
  # @return [String, Array<...>]
  #   - when a block is not given, `OK`
  #   - when a block is given, an array with replies
  #
  # @see #watch
  # @see #unwatch
  def multi
    synchronize do |client|
      if !block_given?
        client.call([:multi])
      else
        begin
          pipeline = Pipeline::Multi.new
          original, @client = @client, pipeline
          yield(self)
          original.call_pipeline(pipeline)
        ensure
          @client = original
        end
      end
    end
  end

  # Execute all commands issued after MULTI.
  #
  # Only call this method when `#multi` was called **without** a block.
  #
  # @return [nil, Array<...>]
  #   - when commands were not executed, `nil`
  #   - when commands were executed, an array with their replies
  #
  # @see #multi
  # @see #discard
  def exec
    synchronize do |client|
      client.call([:exec])
    end
  end

  # Discard all commands issued after MULTI.
  #
  # Only call this method when `#multi` was called **without** a block.
  #
  # @return `"OK"`
  #
  # @see #multi
  # @see #exec
  def discard
    synchronize do |client|
      client.call([:discard])
    end
  end

  # Control remote script registry.
  #
  # @example Load a script
  #   sha = redis.script(:load, "return 1")
  #     # => <sha of this script>
  # @example Check if a script exists
  #   redis.script(:exists, sha)
  #     # => true
  # @example Check if multiple scripts exist
  #   redis.script(:exists, [sha, other_sha])
  #     # => [true, false]
  # @example Flush the script registry
  #   redis.script(:flush)
  #     # => "OK"
  # @example Kill a running script
  #   redis.script(:kill)
  #     # => "OK"
  #
  # @param [String] subcommand e.g. `exists`, `flush`, `load`, `kill`
  # @param [Array<String>] args depends on subcommand
  # @return [String, Boolean, Array<Boolean>, ...] depends on subcommand
  #
  # @see #eval
  # @see #evalsha
  def script(subcommand, *args)
    subcommand = subcommand.to_s.downcase

    if subcommand == "exists"
      synchronize do |client|
        arg = args.first

        client.call([:script, :exists, arg]) do |reply|
          reply = reply.map { |r| _boolify.call(r) }

          if arg.is_a?(Array)
            reply
          else
            reply.first
          end
        end
      end
    else
      synchronize do |client|
        client.call([:script, subcommand] + args)
      end
    end
  end

  def _eval(cmd, args)
    script = args.shift
    options = args.pop if args.last.is_a?(Hash)
    options ||= {}

    keys = args.shift || options[:keys] || []
    argv = args.shift || options[:argv] || []

    synchronize do |client|
      client.call([cmd, script, keys.length] + keys + argv)
    end
  end

  # Evaluate Lua script.
  #
  # @example EVAL without KEYS nor ARGV
  #   redis.eval("return 1")
  #     # => 1
  # @example EVAL with KEYS and ARGV as array arguments
  #   redis.eval("return { KEYS, ARGV }", ["k1", "k2"], ["a1", "a2"])
  #     # => [["k1", "k2"], ["a1", "a2"]]
  # @example EVAL with KEYS and ARGV in a hash argument
  #   redis.eval("return { KEYS, ARGV }", :keys => ["k1", "k2"], :argv => ["a1", "a2"])
  #     # => [["k1", "k2"], ["a1", "a2"]]
  #
  # @param [Array<String>] keys optional array with keys to pass to the script
  # @param [Array<String>] argv optional array with arguments to pass to the script
  # @param [Hash] options
  #   - `:keys => Array<String>`: optional array with keys to pass to the script
  #   - `:argv => Array<String>`: optional array with arguments to pass to the script
  # @return depends on the script
  #
  # @see #script
  # @see #evalsha
  def eval(*args)
    _eval(:eval, args)
  end

  # Evaluate Lua script by its SHA.
  #
  # @example EVALSHA without KEYS nor ARGV
  #   redis.evalsha(sha)
  #     # => <depends on script>
  # @example EVALSHA with KEYS and ARGV as array arguments
  #   redis.evalsha(sha, ["k1", "k2"], ["a1", "a2"])
  #     # => <depends on script>
  # @example EVALSHA with KEYS and ARGV in a hash argument
  #   redis.evalsha(sha, :keys => ["k1", "k2"], :argv => ["a1", "a2"])
  #     # => <depends on script>
  #
  # @param [Array<String>] keys optional array with keys to pass to the script
  # @param [Array<String>] argv optional array with arguments to pass to the script
  # @param [Hash] options
  #   - `:keys => Array<String>`: optional array with keys to pass to the script
  #   - `:argv => Array<String>`: optional array with arguments to pass to the script
  # @return depends on the script
  #
  # @see #script
  # @see #eval
  def evalsha(*args)
    _eval(:evalsha, args)
  end

  def id
    synchronize do |client|
      client.id
    end
  end

  def inspect
    synchronize do |client|
      "#<Redis client v#{Redis::VERSION} for #{client.id}>"
    end
  end

  def method_missing(command, *args)
    synchronize do |client|
      client.call([command] + args)
    end
  end

private

  # Commands returning 1 for true and 0 for false may be executed in a pipeline
  # where the method call will return nil. Propagate the nil instead of falsely
  # returning false.
  def _boolify
    lambda { |value|
      value == 1 if value
    }
  end

  def _hashify
    lambda { |array|
      hash = Hash.new
      array.each_slice(2) do |field, value|
        hash[field] = value
      end
      hash
    }
  end

  def _floatify(str)
    if (inf = str.match(/^(-)?inf/i))
      (inf[1] ? -1.0 : 1.0) / 0.0
    else
      Float str
    end
  end

  def _subscription(method, channels, block)
    return @client.call([method] + channels) if subscribed?

    begin
      original, @client = @client, SubscribedClient.new(@client)
      @client.send(method, *channels, &block)
    ensure
      @client = original
    end
  end

end

require "redis/version"
require "redis/connection"
require "redis/client"
require "redis/pipeline"
require "redis/subscribe"
