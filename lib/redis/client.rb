class Redis
  class Client
    attr_accessor :db, :host, :port, :path, :password, :logger
    attr :timeout
    attr :connection

    def initialize(options = {})
      @path = options[:path]
      if @path.nil?
        @host = options[:host] || "127.0.0.1"
        @port = (options[:port] || 6379).to_i
      end

      @db = (options[:db] || 0).to_i
      @timeout = (options[:timeout] || 5).to_i
      @password = options[:password]
      @logger = options[:logger]
      @connection = Connection.new
    end

    def connect
      establish_connection
      call(:auth, @password) if @password
      call(:select, @db) if @db != 0
      self
    end

    def id
      "redis://#{location}/#{db}"
    end

    def location
      @path || "#{@host}:#{@port}"
    end

    def call(*args)
      reply = process(args) { read }
      raise reply if reply.is_a?(RuntimeError)
      reply
    end

    def call_loop(*args)
      error = nil

      result = without_socket_timeout do
        process(args) do
          loop do
            reply = read
            if reply.is_a?(RuntimeError)
              error = reply
              break
            else
              yield reply
            end
          end
        end
      end

      # Code path is only taken when provided block does a break
      if error
        raise error
      else
        result
      end
    end

    def call_pipelined(commands)
      error = nil

      # Read all replies before raising an error reply to make sure the
      # protocol remains in a consistent state and reconnect is not needed.
      result = process(*commands) do
        Array.new(commands.size) do
          reply = read
          error ||= reply if reply.is_a?(RuntimeError)
          reply
        end
      end

      if error
        raise error
      else
        result
      end
    end

    def call_without_timeout(*args)
      without_socket_timeout do
        call(*args)
      end
    rescue Errno::ECONNRESET
      retry
    end

    def process(*commands)
      logging(commands) do
        ensure_connected do
          commands.each do |command|
            connection.write(command)
          end

          yield if block_given?
        end
      end
    end

    def connected?
      connection.connected?
    end

    def disconnect
      connection.disconnect if connection.connected?
    end

    def reconnect
      disconnect
      connect
    end

    def read
      begin
        connection.read

      rescue Errno::EAGAIN
        # We want to make sure it reconnects on the next command after the
        # timeout. Otherwise the server may reply in the meantime leaving
        # the protocol in a desync status.
        disconnect

        raise Errno::EAGAIN, "Timeout reading from the socket"

      rescue Errno::ECONNRESET
        raise Errno::ECONNRESET, "Connection lost"
      end
    end

    def without_socket_timeout
      connect unless connected?

      begin
        self.timeout = 0
        yield
      ensure
        self.timeout = @timeout if connected?
      end
    end

  protected

    def deprecated(old, new = nil, trace = caller[0])
      message = "The method #{old} is deprecated and will be removed in 2.0"
      message << " - use #{new} instead" if new
      Redis.deprecate(message, trace)
    end

    def logging(commands)
      return yield unless @logger && @logger.debug?

      begin
        commands.each do |name, *args|
          @logger.debug("Redis >> #{name.to_s.upcase} #{args.join(" ")}")
        end

        t1 = Time.now
        yield
      ensure
        @logger.debug("Redis >> %0.2fms" % ((Time.now - t1) * 1000))
      end
    end

    def establish_connection
      # Need timeout in usecs, like socket timeout.
      timeout = Integer(@timeout * 1_000_000)

      if @path
        connection.connect_unix(@path, timeout)
      else
        connection.connect(@host, @port, timeout)
      end

      # If the timeout is set we set the low level socket options in order
      # to make sure a blocking read will return after the specified number
      # of seconds. This hack is from memcached ruby client.
      self.timeout = @timeout

    rescue Errno::ECONNREFUSED
      raise Errno::ECONNREFUSED, "Unable to connect to Redis on #{location}"
    end

    def timeout=(timeout)
      connection.timeout = Integer(timeout * 1_000_000)
    end

    def ensure_connected
      connect unless connected?

      begin
        yield
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF
        if reconnect
          yield
        else
          raise Errno::ECONNRESET
        end
      rescue Exception
        disconnect
        raise
      end
    end

    class ThreadSafe < self
      def initialize(*args)
        require "monitor"

        super(*args)
        @mutex = ::Monitor.new
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def ensure_connected(&block)
        synchronize { super }
      end
    end
  end
end
