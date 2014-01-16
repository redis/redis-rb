require "socket"

module RedisMock
  class Server
    VERBOSE = false

    def initialize(port, options = {}, &block)
      @server = TCPServer.new(options[:host] || "127.0.0.1", port)
      @server.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, true)
    end

    def start(&block)
      @thread = Thread.new { run(&block) }
    end

    # Bail out of @server.accept before closing the socket. This is required
    # to avoid EADDRINUSE after a couple of iterations.
    def shutdown
      @thread.terminate if @thread
      @server.close if @server
    rescue => ex
      $stderr.puts "Error closing mock server: #{ex.message}" if VERBOSE
      $stderr.puts ex.backtrace if VERBOSE
    end

    def run
      loop do
        session = @server.accept

        begin
          return if yield(session) == :exit
        ensure
          session.close
        end
      end
    rescue => ex
      $stderr.puts "Error running mock server: #{ex.message}" if VERBOSE
      $stderr.puts ex.backtrace if VERBOSE
    ensure
      @server.close
    end
  end

  MOCK_PORT = 6382

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
    server = Server.new(MOCK_PORT, options)

    begin
      server.start(&blk)

      yield(MOCK_PORT)

    ensure
      server.shutdown
    end
  end

  # Starts a mock Redis server in a thread.
  #
  # The server will reply with a `+OK` to all commands, but you can
  # customize it by providing a hash. For example:
  #
  #   RedisMock.start(:ping => lambda { "+PONG" }) do
  #     assert_equal "PONG", Redis.new(:port => MOCK_PORT).ping
  #   end
  #
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
        blk = commands[command.to_sym]
        blk ||= lambda { |*_| "+OK" }

        response = blk.call(*argv)

        # Convert a nil response to :close
        response ||= :close

        if response == :exit
          break :exit
        elsif response == :close
          break :close
        elsif response.is_a?(Array)
          session.write("*%d\r\n" % response.size)
          response.each do |e|
            session.write("$%d\r\n%s\r\n" % [e.length, e])
          end
        else
          session.write(response)
          session.write("\r\n") unless response.end_with?("\r\n")
        end
      end
    end

    start_with_handler(handler, options, &blk)
  end
end
