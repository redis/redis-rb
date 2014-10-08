require "redis/connection/registry"
require "redis/errors"
require "hiredis/connection"
require "timeout"

class Redis
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
        @reader, @writer = IO.pipe
        listen_connection_closed
      end

      def listen_connection_closed
        @monitoring_thread = Thread.new do
          loop do
            unless @reader.closed?
              IO.select([@reader], nil, nil, nil)
              raise Errno::ECONNABORTED
            end
          end
        end
      end

      def connected?
        @connection && @connection.connected?
      end

      def timeout=(timeout)
        # Hiredis works with microsecond timeouts
        @connection.timeout = Integer(timeout * 1_000_000)
      end

      def disconnect
        @writer.write('q') unless @writer.closed?
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

Redis::Connection.drivers << Redis::Connection::Hiredis
