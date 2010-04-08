class Redis
  class Client
    class ProtocolError < RuntimeError
      def initialize(reply_type)
        super("Protocol error, got '#{reply_type}' as initial reply byte")
      end
    end

    OK      = "OK".freeze
    MINUS    = "-".freeze
    PLUS     = "+".freeze
    COLON    = ":".freeze
    DOLLAR   = "$".freeze
    ASTERISK = "*".freeze

    BULK_COMMANDS = {
      "set"       => true,
      "setnx"     => true,
      "rpush"     => true,
      "lpush"     => true,
      "lset"      => true,
      "lrem"      => true,
      "sadd"      => true,
      "srem"      => true,
      "sismember" => true,
      "echo"      => true,
      "getset"    => true,
      "smove"     => true,
      "zadd"      => true,
      "zincrby"   => true,
      "zrem"      => true,
      "zscore"    => true,
      "zrank"     => true,
      "zrevrank"  => true,
      "hget"      => true,
      "hdel"      => true,
      "hexists"   => true,
      "publish"   => true
    }

    MULTI_BULK_COMMANDS = {
      "mset"      => true,
      "msetnx"    => true,
      "hset"      => true
    }

    BOOLEAN_PROCESSOR = lambda{|r| r == 1 }

    REPLY_PROCESSOR = {
      "exists"    => BOOLEAN_PROCESSOR,
      "sismember" => BOOLEAN_PROCESSOR,
      "sadd"      => BOOLEAN_PROCESSOR,
      "srem"      => BOOLEAN_PROCESSOR,
      "smove"     => BOOLEAN_PROCESSOR,
      "zadd"      => BOOLEAN_PROCESSOR,
      "zrem"      => BOOLEAN_PROCESSOR,
      "move"      => BOOLEAN_PROCESSOR,
      "setnx"     => BOOLEAN_PROCESSOR,
      "del"       => BOOLEAN_PROCESSOR,
      "renamenx"  => BOOLEAN_PROCESSOR,
      "expire"    => BOOLEAN_PROCESSOR,
      "hset"      => BOOLEAN_PROCESSOR,
      "hexists"   => BOOLEAN_PROCESSOR,
      "info"      => lambda{|r|
        info = {}
        r.each_line {|kv|
          k,v = kv.split(":",2).map{|x| x.chomp}
          info[k.to_sym] = v
        }
        info
      },
      "keys"      => lambda{|r|
        if r.is_a?(Array)
            r
        else
            r.split(" ")
        end
      },
      "hgetall"   => lambda{|r|
        Hash[*r]
      }
    }

    ALIASES = {
      "flush_db"             => "flushdb",
      "flush_all"            => "flushall",
      "last_save"            => "lastsave",
      "key?"                 => "exists",
      "delete"               => "del",
      "randkey"              => "randomkey",
      "list_length"          => "llen",
      "push_tail"            => "rpush",
      "push_head"            => "lpush",
      "pop_tail"             => "rpop",
      "pop_head"             => "lpop",
      "list_set"             => "lset",
      "list_range"           => "lrange",
      "list_trim"            => "ltrim",
      "list_index"           => "lindex",
      "list_rm"              => "lrem",
      "set_add"              => "sadd",
      "set_delete"           => "srem",
      "set_count"            => "scard",
      "set_member?"          => "sismember",
      "set_members"          => "smembers",
      "set_intersect"        => "sinter",
      "set_intersect_store"  => "sinterstore",
      "set_inter_store"      => "sinterstore",
      "set_union"            => "sunion",
      "set_union_store"      => "sunionstore",
      "set_diff"             => "sdiff",
      "set_diff_store"       => "sdiffstore",
      "set_move"             => "smove",
      "set_unless_exists"    => "setnx",
      "rename_unless_exists" => "renamenx",
      "type?"                => "type",
      "zset_add"             => "zadd",
      "zset_count"           => "zcard",
      "zset_range_by_score"  => "zrangebyscore",
      "zset_reverse_range"   => "zrevrange",
      "zset_range"           => "zrange",
      "zset_delete"          => "zrem",
      "zset_score"           => "zscore",
      "zset_incr_by"         => "zincrby",
      "zset_increment_by"    => "zincrby"
    }

    DISABLED_COMMANDS = {
      "monitor" => true,
      "sync"    => true
    }

    BLOCKING_COMMANDS = {
      "blpop" => true,
      "brpop" => true
    }

    def initialize(options = {})
      @host    =  options[:host]    || '127.0.0.1'
      @port    = (options[:port]    || 6379).to_i
      @db      = (options[:db]      || 0).to_i
      @timeout = (options[:timeout] || 5).to_i
      @password = options[:password]
      @logger  =  options[:logger]
      @thread_safe = options[:thread_safe]
      @binary_keys = options[:binary_keys]
      @mutex = Mutex.new if @thread_safe
      @sock = nil
      @pubsub = false

      log(self)
    end

    def to_s
      "Redis Client connected to #{server} against DB #{@db}"
    end

    def select(*args)
      raise "SELECT not allowed, use the :db option when creating the object"
    end

    def [](key)
      get(key)
    end

    def []=(key,value)
      set(key, value)
    end

    def set(key, value, ttl = nil)
      if ttl
        deprecated("set with an expire", :set_with_expire, caller[0])
        set_with_expire(key, value, ttl)
      else
        call_command([:set, key, value])
      end
    end

    def set_with_expire(key, value, ttl)
      multi do
        set(key, value)
        expire(key, ttl)
      end
    end

    def mset(*args)
      if args.size == 1
        deprecated("mset with a hash", :mapped_mset, caller[0])
        mapped_mset(args[0])
      else
        call_command(args.unshift(:mset))
      end
    end

    def mapped_mset(hash)
      mset(*hash.to_a.flatten)
    end

    def msetnx(*args)
      if args.size == 1
        deprecated("msetnx with a hash", :mapped_msetnx, caller[0])
        mapped_msetnx(args[0])
      else
        call_command(args.unshift(:msetnx))
      end
    end

    def mapped_msetnx(hash)
      msetnx(*hash.to_a.flatten)
    end

    # Similar to memcache.rb's #get_multi, returns a hash mapping
    # keys to values.
    def mapped_mget(*keys)
      result = {}
      mget(*keys).each do |value|
        key = keys.shift
        result.merge!(key => value) unless value.nil?
      end
      result
    end

    def sort(key, options = {})
      cmd = []
      cmd << "SORT #{key}"
      cmd << "BY #{options[:by]}" if options[:by]
      cmd << "GET #{[options[:get]].flatten * ' GET '}" if options[:get]
      cmd << "#{options[:order]}" if options[:order]
      cmd << "LIMIT #{options[:limit].join(' ')}" if options[:limit]
      cmd << "STORE #{options[:store]}" if options[:store]
      call_command(cmd)
    end

    def incr(key, increment = nil)
      if increment
        deprecated("incr with an increment", :incrby, caller[0])
        incrby(key, increment)
      else
        call_command([:incr, key])
      end
    end

    def decr(key, decrement = nil)
      if decrement
        deprecated("decr with a decrement", :decrby, caller[0])
        decrby(key, decrement)
      else
        call_command([:decr, key])
      end
    end

    # Ruby defines a now deprecated type method so we need to override it here
    # since it will never hit method_missing
    def type(key)
      call_command(['type', key])
    end

    def quit
      call_command(['quit'])
    rescue Errno::ECONNRESET
    end

    def pipelined(&block)
      pipeline = Pipeline.new self
      yield pipeline
      pipeline.execute
    end

    def exec
      # Need to override Kernel#exec.
      call_command([:exec])
    end

    def multi(&block)
      result = call_command [:multi]

      return result unless block_given?

      begin
        yield(self)
        exec
      rescue Exception => e
        discard
        raise e
      end
    end

    def subscribe(*classes)
      # Top-level `subscribe` MUST be called with a block,
      # nested `subscribe` MUST NOT be called with a block
      if !@pubsub && !block_given?
        raise "Top-level subscribe requires a block"
      elsif @pubsub == true && block_given?
        raise "Nested subscribe does not take a block"
      elsif @pubsub
        # If we're already pubsub'ing, just subscribe us to some more classes
        call_command [:subscribe,*classes]
        return true
      end

      @pubsub = true
      call_command [:subscribe,*classes]
      sub = Subscription.new
      yield(sub)
      begin
        while true
          type, *reply = read_reply # type, [class,data]
          case type
          when 'subscribe','unsubscribe'
            sub.send(type) && sub.send(type).call(reply[0],reply[1])
          when 'message'
            sub.send(type) && sub.send(type).call(reply[0],reply[1])
          end
          break if type == 'unsubscribe' && reply[1] == 0
        end
      rescue RuntimeError
        call_command [:unsubscribe]
        raise
      ensure
        @pubsub = false
      end
    end

    # Wrap raw_call_command to handle reconnection on socket error. We
    # try to reconnect just one time, otherwise let the error araise.
    def call_command(argv)
      log(argv.inspect, :debug)

      connect_to_server unless connected?

      begin
        raw_call_command(argv.dup)
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED
        if reconnect
          raw_call_command(argv.dup)
        else
          raise Errno::ECONNRESET
        end
      end
    end

    def server
      "#{@host}:#{@port}"
    end

    def connect_to(host, port)

      # We support connect_to() timeout only if system_timer is availabe
      # or if we are running against Ruby >= 1.9
      # Timeout reading from the socket instead will be supported anyway.
      if @timeout != 0 and Timer
        begin
          @sock = TCPSocket.new(host, port)
        rescue Timeout::Error
          @sock = nil
          raise Timeout::Error, "Timeout connecting to the server"
        end
      else
        @sock = TCPSocket.new(host, port)
      end

      @sock.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1

      # If the timeout is set we set the low level socket options in order
      # to make sure a blocking read will return after the specified number
      # of seconds. This hack is from memcached ruby client.
      set_socket_timeout!(@timeout) if @timeout

    rescue Errno::ECONNREFUSED
      raise Errno::ECONNREFUSED, "Unable to connect to Redis on #{host}:#{port}"
    end

    def connect_to_server
      connect_to(@host, @port)
      call_command([:auth, @password]) if @password
      call_command([:select, @db]) if @db != 0
      @sock
    end

    def method_missing(*argv)
      call_command(argv)
    end

    def raw_call_command(argvp)
      if argvp[0].is_a?(Array)
        argvv = argvp
        pipeline = true
      else
        argvv = [argvp]
        pipeline = false
      end

      if @binary_keys or pipeline or MULTI_BULK_COMMANDS[argvv[0][0].to_s]
        command = ""
        argvv.each do |argv|
          command << "*#{argv.size}\r\n"
          argv.each{|a|
            a = a.to_s
            command << "$#{get_size(a)}\r\n"
            command << a
            command << "\r\n"
          }
        end
      else
        command = ""
        argvv.each do |argv|
          bulk = nil
          argv[0] = argv[0].to_s
          if ALIASES[argv[0]]
            deprecated(argv[0], ALIASES[argv[0]], caller[4])
            argv[0] = ALIASES[argv[0]]
          end
          raise "#{argv[0]} command is disabled" if DISABLED_COMMANDS[argv[0]]
          if BULK_COMMANDS[argv[0]] and argv.length > 1
            bulk = argv[-1].to_s
            argv[-1] = get_size(bulk)
          end
          command << "#{argv.join(' ')}\r\n"
          command << "#{bulk}\r\n" if bulk
        end
      end
      # When in Pub/Sub mode we don't read replies synchronously.
      if @pubsub
        @sock.write(command)
        return true
      end
      # The normal command execution is reading and processing the reply.
      results = maybe_lock do
        begin
          set_socket_timeout!(0) if requires_timeout_reset?(argvv[0][0].to_s)
          process_command(command, argvv)
        ensure
          set_socket_timeout!(@timeout) if requires_timeout_reset?(argvv[0][0].to_s)
        end
      end

      return pipeline ? results : results[0]
    end

    def process_command(command, argvv)
      @sock.write(command)
      argvv.map do |argv|
        processor = REPLY_PROCESSOR[argv[0].to_s]
        processor ? processor.call(read_reply) : read_reply
      end
    end

    def maybe_lock(&block)
      if @thread_safe
        @mutex.synchronize(&block)
      else
        block.call
      end
    end

    def read_reply

      # We read the first byte using read() mainly because gets() is
      # immune to raw socket timeouts.
      begin
        reply_type = @sock.read(1)
      rescue Errno::EAGAIN

        # We want to make sure it reconnects on the next command after the
        # timeout. Otherwise the server may reply in the meantime leaving
        # the protocol in a desync status.
        disconnect

        raise Errno::EAGAIN, "Timeout reading from the socket"
      end

      raise Errno::ECONNRESET, "Connection lost" unless reply_type

      format_reply(reply_type, @sock.gets)
    end


    if "".respond_to?(:bytesize)
      def get_size(string)
        string.bytesize
      end
    else
      def get_size(string)
        string.size
      end
    end

  private

    def log(str, level = :info)
      @logger.send(level, str.to_s) if @logger
    end

    def deprecated(old, new, trace = caller[0])
      $stderr.puts "\nRedis: The method #{old} is deprecated. Use #{new} instead (in #{trace})"
    end

    def requires_timeout_reset?(command)
      BLOCKING_COMMANDS[command] && @timeout
    end

    def set_socket_timeout!(timeout)
      secs   = Integer(timeout)
      usecs  = Integer((timeout - secs) * 1_000_000)
      optval = [secs, usecs].pack("l_2")
      begin
        @sock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, optval
        @sock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, optval
      rescue Exception => e
        # Solaris, for one, does not like/support socket timeouts.
        log("Unable to use raw socket timeouts: #{e.class.name}: #{e.message}")
      end
    end

    def connected?
      !! @sock
    end

    def disconnect
      begin
        @sock.close
      rescue
      ensure
        @sock = nil
      end
      true
    end

    def reconnect
      disconnect && connect_to_server
    end

    def format_reply(reply_type, line)
      case reply_type
      when MINUS    then format_error_reply(line)
      when PLUS     then format_status_reply(line)
      when COLON    then format_integer_reply(line)
      when DOLLAR   then format_bulk_reply(line)
      when ASTERISK then format_multi_bulk_reply(line)
      else raise ProtocolError.new(reply_type)
      end
    end

    def format_error_reply(line)
      raise "-" + line.strip
    end

    def format_status_reply(line)
      line.strip
    end

    def format_integer_reply(line)
      line.to_i
    end

    def format_bulk_reply(line)
      bulklen = line.to_i
      return if bulklen == -1
      reply = @sock.read(bulklen)
      @sock.read(2) # Discard CRLF.
      reply
    end

    def format_multi_bulk_reply(line)
      reply = []
      line.to_i.times { reply << read_reply }
      reply
    end
  end
end
