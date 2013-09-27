require "redis/connection/registry"
require "redis/errors"
require "hiredis/connection"
require "timeout"

module RubyRedis
  module Connection
    class Hiredis

      def self.connect(config)
        connection = ::Hiredis::Connection.new

        if config[:scheme] == "unix"
          connection.connect_unix(config[:path], Integer(config[:timeout] * 1_000_000))
        else
          connection.connect(config[:host], config[:port], Integer(config[:timeout] * 1_000_000))
        end

        instance = new(connection)
        instance.timeout = config[:timeout]
        instance
      rescue Errno::ETIMEDOUT
        raise TimeoutError
      end

      def initialize(connection)
        @connection = connection
      end

      def connected?
        @connection && @connection.connected?
      end

      def timeout=(timeout)
        # Hiredis works with microsecond timeouts
        @connection.timeout = Integer(timeout * 1_000_000)
      end

      def disconnect
        @connection.disconnect
        @connection = nil
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

RubyRedis::Connection.drivers << RubyRedis::Connection::Hiredis
