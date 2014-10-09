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
        @writer.close unless @writer.closed?
        @reader, @writer = IO.pipe
        @connection.disconnect
        @connection = nil
      end

      def write(command)
        @connection.write(command.flatten(1))
      rescue Errno::EAGAIN
        raise TimeoutError
      end

      def read
        begin
          @monitoring_thread.abort_on_exception = true
          reply = @connection.read
          reply = CommandError.new(reply.message) if reply.is_a?(RuntimeError)
          reply
        ensure
          @monitoring_thread.abort_on_exception = false
        end
      rescue Errno::EAGAIN
        raise TimeoutError
      rescue RuntimeError => err
        raise ProtocolError.new(err.message)
      end

      if defined?(RUBY_ENGINE) && RUBY_ENGINE == "jruby"

        def initialize(connection)
          @connection = connection
          @result_queue = Queue.new
          @read_queue = Queue.new
          listen_connection_closed
        end

        def read
          begin
            @monitoring_thread.abort_on_exception = true

            @read_queue << ''
            reply = @result_queue.pop
            reply = CommandError.new(reply.message) if reply.is_a?(RuntimeError)
            raise reply if reply.is_a?(Errno::ECONNABORTED)

            reply
          ensure
            @monitoring_thread.abort_on_exception = false
          end
        rescue Errno::EAGAIN
          raise TimeoutError
        rescue RuntimeError => err
          raise ProtocolError.new(err.message)
        end

        def listen_connection_closed
          @monitoring_thread = Thread.new do
            loop do
              @read_queue.pop
              @result_queue << @connection.read
            end
          end
        end

        def disconnect
          @result_queue << Errno::ECONNABORTED.new
          @connection.disconnect
          @result_queue.clear
          @connection = nil
        end

      end
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Hiredis
