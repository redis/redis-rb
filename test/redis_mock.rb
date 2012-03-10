require "socket"

module RedisMock
  class Server
    VERBOSE = false

    def initialize(port = 6380, &block)
      @server = TCPServer.new("127.0.0.1", port)
      @server.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, true)
      @thread = Thread.new { run(&block) }
    end
    
    # Bail out of @server.accept before closing the socket. This is required
    # to avoid EADDRINUSE after a couple of iterations.
    def shutdown
      if @thread
        @thread.terminate
        @thread.join
      end
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
    # Starts a mock Redis server in a thread on port 6380.
    #
    # The server will reply with a `+OK` to all commands, but you can
    # customize it by providing a hash. For example:
    #
    #     redis_mock(:ping => lambda { "+PONG" }) do
    #       assert_equal "PONG", Redis.new(:port => 6380).ping
    #     end
    #
    def redis_mock(replies = {})
      begin
        server = Server.new do |command, *args|
          (replies[command.to_sym] || lambda { |*_| "+OK" }).call(*args)
        end

        sleep 0.1 # Give time for the socket to start listening.

        yield

      ensure
        server.shutdown if server
      end
    end
  end
end
