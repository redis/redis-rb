require "redis/errors"

class Redis
  class Client
    attr_accessor :uri, :db, :logger
    attr :timeout
    attr :connection
    attr :command_map

    def initialize(options = {})
      @uri = options[:uri]

      if scheme == 'unix'
        @db = 0
      else
        @db = uri.path[1..-1].to_i
      end

      @timeout = (options[:timeout] || 5).to_f
      @logger = options[:logger]
      @reconnect = true
      @connection = Connection.drivers.last.new
      @command_map = {}
    end

    def connect
      establish_connection
      call [:auth, password] if password
      call [:select, @db] if @db != 0
      self
    end

    def id
      safe_uri
    end

    def safe_uri
      temp_uri = @uri
      temp_uri.user = nil
      temp_uri.password = nil
      temp_uri
    end

    def host
      @uri.host
    end

    def password
      @uri.password
    end

    def path
      @uri.path
    end

    def port
      @uri.port
    end

    def scheme
      @uri.scheme
    end

    def call(command, &block)
      reply = process([command]) { read }
      raise reply if reply.is_a?(CommandError)

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
            if reply.is_a?(CommandError)
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

    def call_pipeline(pipeline)
      without_reconnect_wrapper = lambda do |&blk| blk.call end
      without_reconnect_wrapper = lambda do |&blk|
        without_reconnect(&blk)
      end if pipeline.without_reconnect?

      shutdown_wrapper = lambda do |&blk| blk.call end
      shutdown_wrapper = lambda do |&blk|
        begin
          blk.call
        rescue ConnectionError
          # Assume the pipeline was sent in one piece, but execution of
          # SHUTDOWN caused none of the replies for commands that were executed
          # prior to it from coming back around.
          nil
        end
      end if pipeline.shutdown?

      without_reconnect_wrapper.call do
        shutdown_wrapper.call do
          pipeline.finish(call_pipelined(pipeline.commands))
        end
      end
    end

    def call_pipelined(commands)
      return [] if commands.empty?

      # The method #ensure_connected (called from #process) reconnects once on
      # I/O errors. To make an effort in making sure that commands are not
      # executed more than once, only allow reconnection before the first reply
      # has been read. When an error occurs after the first reply has been
      # read, retrying would re-execute the entire pipeline, thus re-issuing
      # already successfully executed commands. To circumvent this, don't retry
      # after the first reply has been read successfully.

      result = Array.new(commands.size)
      reconnect = @reconnect

      begin
        process(commands) do
          result[0] = read

          @reconnect = false

          (commands.size - 1).times do |i|
            result[i + 1] = read
          end
        end
      ensure
        @reconnect = reconnect
      end

      result
    end

    def call_without_timeout(command, &blk)
      without_socket_timeout do
        call(command, &blk)
      end
    rescue ConnectionError
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

    def io
      yield
    rescue TimeoutError
      raise TimeoutError, "Connection timed out"
    rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF, Errno::EINVAL => e
      raise ConnectionError, "Connection lost (%s)" % [e.class.name.split("::").last]
    end

    def read
      io do
        connection.read
      end
    end

    def write(command)
      io do
        connection.write(command)
      end
    end

    def without_socket_timeout
      connect unless connected?

      begin
        connection.timeout = 0
        yield
      ensure
        connection.timeout = @timeout if connected?
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
          @logger.debug("Redis >> #{name.to_s.upcase} #{args.map(&:to_s).join(" ")}")
        end

        t1 = Time.now
        yield
      ensure
        @logger.debug("Redis >> %0.2fms" % ((Time.now - t1) * 1000)) if t1
      end
    end

    def establish_connection
      if @uri.scheme == 'unix'
        connection.connect_unix(@uri.path, timeout)
      else
        connection.connect(@uri, timeout)
      end

      connection.timeout = @timeout

    rescue TimeoutError
      raise CannotConnectError, "Timed out connecting to Redis on #{safe_uri}"
    rescue Errno::ECONNREFUSED
      raise CannotConnectError, "Error connecting to Redis on #{safe_uri} (ECONNREFUSED)"
    end

    def ensure_connected
      tries = 0

      begin
        connect unless connected?
        tries += 1

        yield
      rescue ConnectionError
        disconnect

        if tries < 2 && @reconnect
          retry
        else
          raise
        end
      rescue Exception
        disconnect
        raise
      end
    end
  end
end
