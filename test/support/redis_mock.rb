# frozen_string_literal: true

require "socket"

module RedisMock
  class Server
    def initialize(options = {})
      tcp_server = TCPServer.new(options[:host] || "127.0.0.1", 0)
      tcp_server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)

      @concurrent = options.delete(:concurrent)

      if options[:ssl]
        ctx = OpenSSL::SSL::SSLContext.new

        ssl_params = options.fetch(:ssl_params, {})
        ctx.set_params(ssl_params) unless ssl_params.empty?

        @server = OpenSSL::SSL::SSLServer.new(tcp_server, ctx)
      else
        @server = tcp_server
      end
    end

    def port
      @server.addr[1]
    end

    def start(&block)
      @thread = Thread.new { run(&block) }
    end

    def shutdown
      @thread.kill
    end

    def run(&block)
      loop do
        if @concurrent
          Thread.new(@server.accept) do |session|
            block.call(session)
          ensure
            session.close
          end
        else
          session = @server.accept
          begin
            return if yield(session) == :exit
          ensure
            session.close
          end
        end
      end
    rescue => ex
      warn "Error running mock server: #{ex.class}: #{ex.message}"
      warn ex.backtrace
      retry
    ensure
      @server.close
    end
  end

  # Starts a mock Redis server in a thread.
  #
  # The server will use the lambda handler passed as argument to handle
  # connections. For example:
  #
  #   handler = lambda { |session| session.close }
  #   RedisMock.start_with_handler(handler) do
  #     # Every connection will be closed immediately
  #   end
  #
  def self.start_with_handler(blk, options = {})
    server = Server.new(options)
    port = server.port

    begin
      server.start(&blk)
      yield(port)
    ensure
      server.shutdown
    end
  end

  # Starts a mock Redis server in a thread.
  #
  # The server will reply with a `+OK` to all commands, but you can
  # customize it by providing a hash. For example:
  #
  #   RedisMock.start(:ping => lambda { "+PONG" }) do |port|
  #     assert_equal "PONG", Redis.new(:port => port).ping
  #   end
  #
  # Encode a Ruby value as RESP for the mock server: Array -> `*`, Hash -> RESP3 map `%`, and any
  # other value as a bulk string. Recurses so sentinel mocks can return arrays of maps.
  def self.write_resp_value(session, value)
    case value
    when Array
      session.write("*#{value.size}\r\n")
      value.each { |element| write_resp_value(session, element) }
    when Hash
      session.write("%#{value.size}\r\n")
      value.each do |key, val|
        write_resp_value(session, key)
        write_resp_value(session, val)
      end
    else
      str = value.to_s
      session.write("$#{str.bytesize}\r\n#{str}\r\n")
    end
  end

  def self.start(commands, options = {}, &blk)
    handler = lambda do |session|
      while line = session.gets
        argv = Array.new(line[1..-3].to_i) do
          bytes = session.gets[1..-3].to_i
          arg = session.read(bytes)
          session.read(2) # Discard \r\n
          arg
        end

        command = argv.shift

        # Under RESP3 the client authenticates via `HELLO 3 AUTH <user> <pass>` rather than a
        # separate AUTH command. Unless the test mocks HELLO itself, route the embedded credentials
        # to the `auth` handler (so existing auth mocks still see them) and ack the handshake.
        if command&.casecmp?("HELLO") && !commands.key?(:hello)
          if (auth_idx = argv.index { |a| a.to_s.casecmp?("AUTH") }) && commands[:auth]
            commands[:auth].call(argv[auth_idx + 1], argv[auth_idx + 2])
          end
          session.write("+OK\r\n")
          next
        end

        blk = commands[command.downcase.to_sym]
        blk ||= ->(*_) { "+OK" }

        response = blk.call(*argv)

        # Convert a nil response to :close
        response ||= :close

        case response
        when :exit
          break :exit
        when :close
          break :close
        when Array, Hash
          # Recursively encode arrays (RESP `*`) and hashes (RESP3 map `%`); leaf values are
          # written as bulk strings. This lets sentinel mocks return RESP3-shaped map replies.
          RedisMock.write_resp_value(session, response)
        else
          session.write(response)
          session.write("\r\n") unless response.end_with?("\r\n")
        end
      end
    end

    start_with_handler(handler, options, &blk)
  end
end
