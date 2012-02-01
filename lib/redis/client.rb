class Redis
  class Client
    attr_accessor :db, :host, :port, :path, :password, :logger
    attr :timeout
    attr :connection
    attr :command_map

    def initialize(options = {})
      @path = options[:path]
      if @path.nil?
        @host = options[:host] || "127.0.0.1"
        @port = (options[:port] || 6379).to_i
      end

      @db = (options[:db] || 0).to_i
      @timeout = (options[:timeout] || 5).to_f
      @password = options[:password]
      @logger = options[:logger]
      @reconnect = true
      @connection = Connection.drivers.last.new
      @command_map = {}
    end

    def connect
      establish_connection
      call [:auth, @password] if @password
      call [:select, @db] if @db != 0
      self
    end

    def id
      "redis://#{location}/#{db}"
    end

    def location
      @path || "#{@host}:#{@port}"
    end

    def call(command, &block)
      reply = process([command]) { read }
      raise reply if reply.kind_of?(RuntimeError)

      if block
        block.call(reply)
      else
        reply
      end
    end

    def call_loop(command)
      error = nil

      result = without_socket_timeout do
        process([command]) do
          loop do
            reply = read
            if reply.kind_of?(RuntimeError)
              error = reply
              break
            else
              yield reply
            end
          end
        end
      end

      # Raise error when previous block broke out of the loop.
      raise error if error

      # Result is set to the value that the provided block used to break.
      result
    end

    def call_pipeline(pipeline, options = {})
      without_reconnect_wrapper = lambda do |&blk| blk.call end
      without_reconnect_wrapper = lambda do |&blk|
        without_reconnect(&blk)
      end if pipeline.without_reconnect?

      shutdown_wrapper = lambda do |&blk| blk.call end
      shutdown_wrapper = lambda do |&blk|
        begin
          blk.call
        rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF, Errno::EINVAL
          # Assume the pipeline was sent in one piece, but execution of
          # SHUTDOWN caused none of the replies for commands that were executed
          # prior to it from coming back around.
          []
        end
      end if pipeline.shutdown?

      without_reconnect_wrapper.call do
        shutdown_wrapper.call do
          call_pipelined(pipeline.commands, options).each_with_index.map do |reply, i|
            if block = pipeline.blocks[i]
              block.call(reply)
            else
              reply
            end
          end
        end
      end
    end

    def call_pipelined(commands, options = {})
      options[:raise] = true unless options.has_key?(:raise)

      return [] if commands.empty?

      # The method #ensure_connected (called from #process) reconnects once on
      # I/O errors. To make an effort in making sure that commands are not
      # executed more than once, only allow reconnection before the first reply
      # has been read. When an error occurs after the first reply has been
      # read, retrying would re-execute the entire pipeline, thus re-issueing
      # already succesfully executed commands. To circumvent this, don't retry
      # after the first reply has been read succesfully.
      first = process(commands) { read }
      error = first if first.kind_of?(RuntimeError)

      begin
        remaining = commands.size - 1
        if remaining > 0
          replies = Array.new(remaining) do
            reply = read
            error ||= reply if reply.kind_of?(RuntimeError)
            reply
          end
          replies.unshift first
          replies
        else
          replies = [first]
        end
      rescue Exception
        disconnect
        raise
      end

      # Raise first error in pipeline when we should raise.
      raise error if error && options[:raise]

      replies
    end

    def call_without_timeout(command, &blk)
      without_socket_timeout do
        call(command, &blk)
      end
    rescue Errno::ECONNRESET
      retry
    end

    def process(commands)
      logging(commands) do
        ensure_connected do
          commands.each do |command|
            if command_map[command.first]
              command = command.dup
              command[0] = command_map[command.first]
            end

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

    def without_reconnect
      begin
        original, @reconnect = @reconnect, false
        yield
      ensure
        @reconnect = original
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
      tries = 0

      begin
        connect unless connected?
        tries += 1

        yield
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF, Errno::EINVAL
        disconnect

        if tries < 2 && @reconnect
          retry
        else
          raise Errno::ECONNRESET
        end
      rescue Exception
        disconnect
        raise
      end
    end
  end
end
