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
        EventMachine::Synchrony.sync @req
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

      def initialize
        @timeout = 5.0
        @connection = nil
      end

      def connected?
        @connection && @connection.connected?
      end

      def timeout=(timeout)
        @timeout = timeout
      end

      def connect(uri, timeout)
        conn = EventMachine.connect(uri.host, uri.port, RedisClient) do |c|
          c.pending_connect_timeout = [timeout, 0.1].max
        end

        setup_connect_callbacks(conn, Fiber.current)
      end

      def connect_unix(path, timeout)
        conn = EventMachine.connect_unix_domain(path, RedisClient)
        setup_connect_callbacks(conn, Fiber.current)
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

    private

      def setup_connect_callbacks(conn, f)
        conn.callback do
          @connection = conn
          f.resume conn
        end

        conn.errback do
          @connection = conn
          f.resume :refused
        end

        r = Fiber.yield
        raise Errno::ECONNREFUSED if r == :refused
        r
      end
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Synchrony
