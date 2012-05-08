require "socket"

module RedisMock
  class Server
    VERBOSE = false

    def initialize(port, &block)
      @server = TCPServer.new("127.0.0.1", port)
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
          while line = session.gets
            parts = Array.new(line[1..-3].to_i) do
              bytes = session.gets[1..-3].to_i
              argument = session.read(bytes)
              session.read(2) # Discard \r\n
              argument
            end

            response = yield(*parts)

            # Convert a nil response to :close
            response ||= :close

            if response == :exit
              session.shutdown(Socket::SHUT_RDWR)
              return # exit server body
            elsif response == :close
              session.shutdown(Socket::SHUT_RDWR)
              break # exit connection body
            else
              session.write(response)
              session.write("\r\n") unless response.end_with?("\r\n")
            end
          end
        rescue Errno::ECONNRESET
          # Ignore client closing the connection
        end
      end
    rescue => ex
      $stderr.puts "Error running mock server: #{ex.message}" if VERBOSE
      $stderr.puts ex.backtrace if VERBOSE
    ensure
      @server.close
    end
  end

  module Helper

    MOCK_PORT = 6382

    # Starts a mock Redis server in a thread.
    #
    # The server will reply with a `+OK` to all commands, but you can
    # customize it by providing a hash. For example:
    #
    #     redis_mock(:ping => lambda { "+PONG" }) do
    #       assert_equal "PONG", Redis.new(:port => MOCK_PORT).ping
    #     end
    #
    def redis_mock(replies = {})
      server = Server.new(MOCK_PORT)

      begin
        server.start do |command, *args|
          (replies[command.to_sym] || lambda { |*_| "+OK" }).call(*args)
        end

        sleep 0.1 # Give time for the socket to start listening.

        yield

      ensure
        server.shutdown
        sleep 0.1 # Allow some time for cleanup
      end
    end
  end
end
