require "redis/connection/command_helper"
require "redis/connection/registry"
require "redis/errors"
require "em-synchrony"
require "hiredis/reader"

class Redis
  module Connection
    class RedisClient < EventMachine::Connection
      include EventMachine::Deferrable

      def post_init
        @req = nil
        @connected = false
        @reader = ::Hiredis::Reader.new
      end

      def connection_completed
        @connected = true
        succeed
      end

      def connected?
        @connected
      end

      def timeout=(secs)
        @timeout = secs
      end

      def receive_data(data)
        @reader.feed(data)

        begin
          until (reply = @reader.gets) == false
            reply = CommandError.new(reply.message) if reply.is_a?(RuntimeError)
            @req.succeed [:reply, reply]
          end
        rescue RuntimeError => err
          @req.fail [:error, ProtocolError.new(err.message)]
        end
      end

      def read
        @req = EventMachine::DefaultDeferrable.new
        @req.timeout @timeout if @timeout
        data = EventMachine::Synchrony.sync @req
        data.nil? ? [:error, 'Read timeout occurred'] : data
      end

      def send(data)
        callback { send_data data }
      end

      def unbind
        @connected = false
        if @req
          @req.fail [:error, Errno::ECONNRESET]
          @req = nil
        else
          fail
        end
      end
    end

    class Synchrony
      include Redis::Connection::CommandHelper

      def self.connect(config)
        if config[:scheme] == "unix"
          conn = EventMachine.connect_unix_domain(config[:path], RedisClient)
        else
          conn = EventMachine.connect(config[:host], config[:port], RedisClient) do |c|
            c.pending_connect_timeout = [config[:timeout], 0.1].max
          end
        end

        fiber = Fiber.current
        conn.callback { fiber.resume }
        conn.errback { fiber.resume :refused }

        raise Errno::ECONNREFUSED if Fiber.yield == :refused

        instance = new(conn)
        instance.timeout = config[:timeout]
        instance
      end

      def initialize(connection)
        @connection = connection
      end

      def connected?
        @connection && @connection.connected?
      end

      def timeout=(timeout)
        @connection.timeout = timeout
        @timeout = timeout
      end

      def disconnect
        @connection.close_connection
        @connection = nil
      end

      def write(command)
        @connection.send(build_command(command))
      end

      def read
        type, payload = @connection.read

        if type == :reply
          payload
        elsif type == :error
          raise payload
        else
          raise "Unknown type #{type.inspect}"
        end
      end
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Synchrony
