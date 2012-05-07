require "redis/connection/registry"
require "redis/errors"
require "hiredis/connection"
require "timeout"

class Redis
  module Connection
    class Hiredis
      def initialize
        @connection = ::Hiredis::Connection.new
      end

      def connected?
        @connection.connected?
      end

      def timeout=(timeout)
        # Hiredis works with microsecond timeouts
        @connection.timeout = Integer(timeout * 1_000_000)
      end

      def connect(config)
        if config[:scheme] == "unix"
          @connection.connect_unix(config[:path], Integer(config[:timeout] * 1_000_000))
        else
          @connection.connect(config[:host], config[:port], Integer(config[:timeout] * 1_000_000))
        end

      rescue Errno::ETIMEDOUT
        raise TimeoutError
      end

      def disconnect
        @connection.disconnect
      end

      def write(command)
        @connection.write(command.flatten(1))
      rescue Errno::EAGAIN
        raise TimeoutError
      end

      def read
        reply = @connection.read
        reply = CommandError.new(reply.message) if reply.is_a?(RuntimeError)
        reply
      rescue Errno::EAGAIN
        raise TimeoutError
      rescue RuntimeError => err
        raise ProtocolError.new(err.message)
      end
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Hiredis
