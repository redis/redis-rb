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
        @monitoring_thread = nil
        @writer = nil
      end

      def connected?
        @connection && @connection.connected?
      end

      def timeout=(timeout)
        # Hiredis works with microsecond timeouts
        @connection.timeout = Integer(timeout * 1_000_000)
      end

      def disconnect
        @monitoring_thread.terminate if @monitoring_thread
        @writer.close if @writer && !@writer.closed?
        @connection.disconnect
        @connection = nil
      end

      def write(command)
        @connection.write(command.flatten(1))
      rescue Errno::EAGAIN
        raise TimeoutError
      end

      def read
        read_result = read_with_pipe

        begin
          @monitoring_thread.join
        rescue Errno::EAGAIN
          raise TimeoutError
        rescue RuntimeError => err
          raise ProtocolError.new(err.message)
        rescue Exception => ex
          raise unless ex.message =~ /expired/ # Jruby can raise anonynous exceptions (<#<Class:12653: execution expired>>)...
        end

        raise TimeoutError if read_result != "Done"
        @reply = CommandError.new(@reply.message) if @reply.is_a?(RuntimeError)
        @reply
      end

      def read_with_pipe
        reader, @writer = IO.pipe

        @monitoring_thread = Thread.new do
          begin
            @reply = @connection.read
            @writer.write("Done")
          ensure
            @writer.close unless @writer.closed?
          end
        end

        reader.read
      ensure
        reader.close
      end
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Hiredis
