require "redis/connection/registry"
require "redis/connection/command_helper"
require "redis/errors"
require "socket"
require "timeout"

begin
  require "openssl"
rescue LoadError
  # Not all systems have OpenSSL support
end

if RUBY_VERSION < "1.9.3"
  class String
    # Ruby 1.8.7 does not have byteslice, but it handles encodings differently anyway.
    # We can simply slice the string, which is a byte array there.
    def byteslice(*args)
      slice(*args)
    end
  end
end

class Redis
  module Connection
    module SocketMixin

      CRLF = "\r\n".freeze

      # Exceptions raised during non-blocking I/O ops that require retrying the op
      if RUBY_VERSION >= "1.9.3"
        NBIO_READ_EXCEPTIONS = [IO::WaitReadable]
        NBIO_WRITE_EXCEPTIONS = [IO::WaitWritable]
      else
        NBIO_READ_EXCEPTIONS = [Errno::EWOULDBLOCK, Errno::EAGAIN]
        NBIO_WRITE_EXCEPTIONS = [Errno::EWOULDBLOCK, Errno::EAGAIN]
      end

      def initialize(*args)
        super(*args)

        @timeout = @write_timeout = nil
        @buffer = ""
      end

      def timeout=(timeout)
        if timeout && timeout > 0
          @timeout = timeout
        else
          @timeout = nil
        end
      end

      def write_timeout=(timeout)
        if timeout && timeout > 0
          @write_timeout = timeout
        else
          @write_timeout = nil
        end
      end

      def read(nbytes)
        result = @buffer.slice!(0, nbytes)

        while result.bytesize < nbytes
          result << _read_from_socket(nbytes - result.bytesize)
        end

        result
      end

      def gets
        crlf = nil

        while (crlf = @buffer.index(CRLF)) == nil
          @buffer << _read_from_socket(1024)
        end

        @buffer.slice!(0, crlf + CRLF.bytesize)
      end

      def _read_from_socket(nbytes)

        begin
          read_nonblock(nbytes)

        rescue *NBIO_READ_EXCEPTIONS
          if IO.select([self], nil, nil, @timeout)
            retry
          else
            raise Redis::TimeoutError
          end
        rescue *NBIO_WRITE_EXCEPTIONS
          if IO.select(nil, [self], nil, @timeout)
            retry
          else
            raise Redis::TimeoutError
          end
        end

      rescue EOFError
        raise Errno::ECONNRESET
      end

      def _write_to_socket(data)
        begin
          write_nonblock(data)

        rescue *NBIO_WRITE_EXCEPTIONS
          if IO.select(nil, [self], nil, @write_timeout)
            retry
          else
            raise Redis::TimeoutError
          end
        rescue *NBIO_READ_EXCEPTIONS
          if IO.select([self], nil, nil, @write_timeout)
            retry
          else
            raise Redis::TimeoutError
          end
        end

      rescue EOFError
        raise Errno::ECONNRESET
      end

      def write(data)
        return super(data) unless @write_timeout

        length = data.bytesize
        total_count = 0
        loop do
          count = _write_to_socket(data)

          total_count += count
          return total_count if total_count >= length
          data = data.byteslice(count..-1)
        end
      end
    end

    if defined?(RUBY_ENGINE) && RUBY_ENGINE == "jruby"

      require "timeout"

      class TCPSocket < ::TCPSocket

        include SocketMixin

        def self.connect(host, port, timeout)
          Timeout.timeout(timeout) do
            sock = new(host, port)
            sock
          end
        rescue Timeout::Error
          raise TimeoutError
        end
      end

      if defined?(::UNIXSocket)

        class UNIXSocket < ::UNIXSocket

          include SocketMixin

          def self.connect(path, timeout)
            Timeout.timeout(timeout) do
              sock = new(path)
              sock
            end
          rescue Timeout::Error
            raise TimeoutError
          end

          # JRuby raises Errno::EAGAIN on #read_nonblock even when IO.select
          # says it is readable (1.6.6, in both 1.8 and 1.9 mode).
          # Use the blocking #readpartial method instead.

          def _read_from_socket(nbytes)
            readpartial(nbytes)

          rescue EOFError
            raise Errno::ECONNRESET
          end
        end

      end

    else

      class TCPSocket < ::Socket

        include SocketMixin

        def self.connect_addrinfo(ai, port, timeout)
          sock = new(::Socket.const_get(ai[0]), Socket::SOCK_STREAM, 0)
          sockaddr = ::Socket.pack_sockaddr_in(port, ai[3])

          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::EINPROGRESS
            if IO.select(nil, [sock], nil, timeout) == nil
              raise TimeoutError
            end

            begin
              sock.connect_nonblock(sockaddr)
            rescue Errno::EISCONN
            end
          end

          sock
        end

        def self.connect(host, port, timeout)
          # Don't pass AI_ADDRCONFIG as flag to getaddrinfo(3)
          #
          # From the man page for getaddrinfo(3):
          #
          #   If hints.ai_flags includes the AI_ADDRCONFIG flag, then IPv4
          #   addresses are returned in the list pointed to by res only if the
          #   local system has at least one IPv4 address configured, and IPv6
          #   addresses are returned only if the local system has at least one
          #   IPv6 address configured. The loopback address is not considered
          #   for this case as valid as a configured address.
          #
          # We do want the IPv6 loopback address to be returned if applicable,
          # even if it is the only configured IPv6 address on the machine.
          # Also see: https://github.com/redis/redis-rb/pull/394.
          addrinfo = ::Socket.getaddrinfo(host, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)

          # From the man page for getaddrinfo(3):
          #
          #   Normally, the application should try using the addresses in the
          #   order in which they are returned. The sorting function used
          #   within getaddrinfo() is defined in RFC 3484 [...].
          #
          addrinfo.each_with_index do |ai, i|
            begin
              return connect_addrinfo(ai, port, timeout)
            rescue SystemCallError
              # Raise if this was our last attempt.
              raise if addrinfo.length == i+1
            end
          end
        end
      end

      class UNIXSocket < ::Socket

        include SocketMixin

        def self.connect(path, timeout)
          sock = new(::Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
          sockaddr = ::Socket.pack_sockaddr_un(path)

          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::EINPROGRESS
            if IO.select(nil, [sock], nil, timeout) == nil
              raise TimeoutError
            end

            begin
              sock.connect_nonblock(sockaddr)
            rescue Errno::EISCONN
            end
          end

          sock
        end
      end

    end

    if defined?(OpenSSL)
      class SSLSocket < ::OpenSSL::SSL::SSLSocket
        include SocketMixin

        def self.connect(host, port, timeout, ssl_params)
          # Note: this is using Redis::Connection::TCPSocket
          tcp_sock = TCPSocket.connect(host, port, timeout)

          ctx = OpenSSL::SSL::SSLContext.new
          ctx.set_params(ssl_params) if ssl_params && !ssl_params.empty?

          ssl_sock = new(tcp_sock, ctx)
          ssl_sock.hostname = host
          ssl_sock.connect
          ssl_sock.post_connection_check(host)

          ssl_sock
        end
      end
    end

    class Ruby
      include Redis::Connection::CommandHelper

      MINUS    = "-".freeze
      PLUS     = "+".freeze
      COLON    = ":".freeze
      DOLLAR   = "$".freeze
      ASTERISK = "*".freeze

      def self.connect(config)
        if config[:scheme] == "unix"
          raise ArgumentError, "SSL incompatible with unix sockets" if config[:ssl]
          sock = UNIXSocket.connect(config[:path], config[:connect_timeout])
        elsif config[:scheme] == "rediss" || config[:ssl]
          raise ArgumentError, "This library does not support SSL on Ruby < 1.9" if RUBY_VERSION < "1.9.3"
          sock = SSLSocket.connect(config[:host], config[:port], config[:connect_timeout], config[:ssl_params])
        else
          sock = TCPSocket.connect(config[:host], config[:port], config[:connect_timeout])
        end

        instance = new(sock)
        instance.timeout = config[:timeout]
        instance.write_timeout = config[:write_timeout]
        instance.set_tcp_keepalive config[:tcp_keepalive]
        instance
      end

      if [:SOL_SOCKET, :SO_KEEPALIVE, :SOL_TCP, :TCP_KEEPIDLE, :TCP_KEEPINTVL, :TCP_KEEPCNT].all?{|c| Socket.const_defined? c}
        def set_tcp_keepalive(keepalive)
          return unless keepalive.is_a?(Hash)

          @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE,  true)
          @sock.setsockopt(Socket::SOL_TCP,    Socket::TCP_KEEPIDLE,  keepalive[:time])
          @sock.setsockopt(Socket::SOL_TCP,    Socket::TCP_KEEPINTVL, keepalive[:intvl])
          @sock.setsockopt(Socket::SOL_TCP,    Socket::TCP_KEEPCNT,   keepalive[:probes])
        end

        def get_tcp_keepalive
          {
            :time   => @sock.getsockopt(Socket::SOL_TCP, Socket::TCP_KEEPIDLE).int,
            :intvl  => @sock.getsockopt(Socket::SOL_TCP, Socket::TCP_KEEPINTVL).int,
            :probes => @sock.getsockopt(Socket::SOL_TCP, Socket::TCP_KEEPCNT).int,
          }
        end
      else
        def set_tcp_keepalive(keepalive)
        end

        def get_tcp_keepalive
          {
          }
        end
      end

      def initialize(sock)
        @sock = sock
      end

      def connected?
        !! @sock
      end

      def disconnect
        @sock.close
      rescue
      ensure
        @sock = nil
      end

      def timeout=(timeout)
        if @sock.respond_to?(:timeout=)
          @sock.timeout = timeout
        end
      end

      def write_timeout=(timeout)
        @sock.write_timeout = timeout
      end

      def write(command)
        @sock.write(build_command(command))
      end

      def read
        line = @sock.gets
        reply_type = line.slice!(0, 1)
        format_reply(reply_type, line)

      rescue Errno::EAGAIN
        raise TimeoutError
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
        CommandError.new(line.strip)
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
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Ruby
