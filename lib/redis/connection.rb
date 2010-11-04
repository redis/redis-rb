class Redis
  class Connection
    MINUS    = "-".freeze
    PLUS     = "+".freeze
    COLON    = ":".freeze
    DOLLAR   = "$".freeze
    ASTERISK = "*".freeze

    def initialize
      @sock = nil
    end

    def connected?
      !! @sock
    end

    def connect(host, port)
      @sock = TCPSocket.new(host, port)
      @sock.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
    end

    def disconnect
      @sock.close
    rescue
    ensure
      @sock = nil
    end

    def timeout=(usecs)
      secs   = Integer(usecs / 1_000_000)
      usecs  = Integer(usecs - (secs * 1_000_000)) # 0 - 999_999

      optval = [secs, usecs].pack("l_2")

      begin
        @sock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, optval
        @sock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, optval
      rescue Errno::ENOPROTOOPT
      end
    end

    COMMAND_DELIMITER = "\r\n"

    def write(command)
      @sock.write(build_command(*command).join(COMMAND_DELIMITER))
      @sock.write(COMMAND_DELIMITER)
    end

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

    def read
      # We read the first byte using read() mainly because gets() is
      # immune to raw socket timeouts.
      reply_type = @sock.read(1)

      raise Errno::ECONNRESET unless reply_type

      format_reply(reply_type, @sock.gets)
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
      reply = encode(@sock.read(bulklen))
      @sock.read(2) # Discard CRLF.
      reply
    end

    def format_multi_bulk_reply(line)
      n = line.to_i
      return if n == -1

      Array.new(n) { read }
    end

  protected

    if "".respond_to?(:bytesize)
      def string_size(string)
        string.to_s.bytesize
      end
    else
      def string_size(string)
        string.to_s.size
      end
    end

    if defined?(Encoding::default_external)
      def encode(string)
        string.force_encoding(Encoding::default_external)
      end
    else
      def encode(string)
        string
      end
    end
  end
end
