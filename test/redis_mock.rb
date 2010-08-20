require "socket"

module RedisMock
  def self.start(port = 6380)
    server = TCPServer.new("127.0.0.1", port)

    loop do
      session = server.accept

      while line = session.gets
        parts = Array.new(line[1..-3].to_i) do
          bytes = session.gets[1..-3].to_i
          argument = session.read(bytes)
          session.read(2) # Discard \r\n
          argument
        end

        session.read(2) # Discard \r\n

        response = yield(*parts)

        if response.nil?
          session.shutdown
          break
        else
          session.write(response)
          session.write("\r\n")
        end
      end
    end
  end

  module Helper
    # Forks the current process and starts a new mock Redis server on
    # port 6380.
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
        pid = fork do
          trap("TERM") { exit }

          RedisMock.start do |command, *args|
            (replies[command.to_sym] || lambda { |*_| "+OK" }).call(*args)
          end
        end

        sleep 1 # Give time for the socket to start listening.

        yield

      ensure
        if pid
          Process.kill("TERM", pid)
          Process.wait(pid)
        end
      end
    end
  end
end
