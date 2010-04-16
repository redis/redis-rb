require "thread"

class Redis
  class Client
    MINUS    = "-".freeze
    PLUS     = "+".freeze
    COLON    = ":".freeze
    DOLLAR   = "$".freeze
    ASTERISK = "*".freeze

    attr_accessor :db, :host, :port, :password, :timeout, :logger

    def initialize(options = {})
      @host = options[:host] || "127.0.0.1"
      @port = (options[:port] || 6379).to_i
      @db = (options[:db] || 0).to_i
      @timeout = (options[:timeout] || 5).to_i
      @password = options[:password]
      @logger  =  options[:logger]
      @mutex = ::Mutex.new
      @sock = nil
    end

    def connect
      connect_to(@host, @port)
      call(:auth, @password) if @password
      call(:select, @db) if @db != 0
      @sock
    end

    def call(name, *args)
      ensure_connected do
        log("Redis >> #{name.to_s.upcase} #{args.join(" ")}")

        command = build_command(name, *args)

        process_and_read([command]).first
      end
    end

    def call_async(name, *args)
      ensure_connected do
        log("Redis >> #{name.to_s.upcase} #{args.join(" ")}")

        process([build_command(name, *args)])
      end
    end

    def call_pipelined(commands)
      ensure_connected do
        commands = commands.map do |name, *args|
          command = build_command(name, *args)
        end

        process_and_read(commands)
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
      disconnect && connect
    end

    def read

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

    def without_socket_timeout
      begin
        self.timeout = 0
        yield
      ensure
        self.timeout = @timeout
      end
    end

  protected

    def build_command(name, *args)
      command = []
      command << "*#{args.size + 1}"
      command << "$#{string_size name}"
      command << name

      args.each do |arg|
        arg = arg.to_s
        command << "$#{string_size arg}"
        command << arg
      end

      command
    end

    COMMAND_DELIMITER = "\r\n"

    def process(commands)
      @sock.write(join_commands(commands))
    end

    def join_commands(commands)
      commands.map do |command|
        command.join(COMMAND_DELIMITER) + COMMAND_DELIMITER
      end.join(COMMAND_DELIMITER) + COMMAND_DELIMITER
    end

    def process_and_read(commands)
      process(commands)

      @mutex.synchronize do
        Array.new(commands.size).map { read }
      end
    end

    if "".respond_to?(:bytesize)
      def string_size(string)
        string.to_s.bytesize
      end
    else
      def string_size(string)
        string.to_s.size
      end
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
      line.to_i.times { reply << read }
      reply
    end

    def log(str, level = :info)
      @logger.send(level, str.to_s) if @logger
    end

    if defined?(Timeout)
      TimeoutError = Timeout::Error
    else
      TimeoutError = Exception
    end

    def connect_to(host, port)
      begin
        @sock = TCPSocket.new(host, port)
      rescue TimeoutError
        @sock = nil
        raise
      end

      @sock.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1

      # If the timeout is set we set the low level socket options in order
      # to make sure a blocking read will return after the specified number
      # of seconds. This hack is from memcached ruby client.
      self.timeout = @timeout

    rescue Errno::ECONNREFUSED
      raise Errno::ECONNREFUSED, "Unable to connect to Redis on #{host}:#{port}"
    end

    def timeout=(timeout)
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

    def ensure_connected
      connect unless connected?

      begin
        yield
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED
        if reconnect
          yield
        else
          raise Errno::ECONNRESET
        end
      end
    end
  end
end
