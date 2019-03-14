require_relative "command_helper"
require_relative "registry"
require_relative "../errors"
require "async/io/endpoint"
require "async/io/host_endpoint"
require "async/io/unix_endpoint"
require "async/io/stream"
require "hiredis/reader"

class Redis
  module Connection
    class Async
      include Redis::Connection::CommandHelper

      class Endpoint < ::Async::IO::Endpoint
        def initialize(config)
          super(**config)

          @endpoint = nil
        end

        def connect_timeout
          @options[:connect_timeout] || self.timeout
        end

        def endpoint
          @endpoint ||= build_endpoint
        end

        def connect
          peer = endpoint.connect

          # Once connected, set the read/write timeout:
          peer.timeout = self.timeout

          return peer
        end

        protected

        def build_endpoint
          if @options[:scheme] == "unix"
            return ::Async::IO::Endpoint.unix(@options[:path], timeout: self.connect_timeout)
          else
            endpoint = ::Async::IO::Endpoint.tcp(@options[:host], @options[:port], timeout: self.connect_timeout)

            if @options[:scheme] == "rediss" || @options[:ssl]
              endpoint = ::Async::IO::SSLEndpoint.new(endpoint, ssl_params: @options[:ssl_params])
            end

            return endpoint
          end
        end
      end

      def self.endpoint(config)
        Endpoint.new(config)
      end

      def self.connect(config)
        endpoint = self.endpoint(config)

        begin
          @socket = endpoint.connect
        rescue ::Async::TimeoutError
          raise TimeoutError
        end

        self.new(@socket)
      end

      def initialize(socket)
        @socket = socket
        @stream = ::Async::IO::Stream.new(@socket)
        @reader = ::Hiredis::Reader.new
      end

      def connected?
        @stream
      end

      def timeout=(timeout)
        if timeout && timeout > 0
          @socket.timeout = timeout
        else
          @socket.timeout = nil
        end
      end

      def disconnect
        @stream.close
        @stream = nil
        @socket = nil
        @reader = nil
      end

      def write(command)
        @stream.write(build_command(command))
        @stream.flush
      rescue ::Async::TimeoutError
        raise TimeoutError
      end

      def read
        reply = @reader.gets

        while reply == false
          # Read some data:
          if chunk = @stream.read_partial
            @reader.feed(chunk)
          else
            raise Errno::ECONNRESET
          end

          # Parse the reply:
          reply = @reader.gets
        end

        if reply.is_a? RuntimeError
          reply = CommandError.new(reply.message)
        end

        return reply
      rescue RuntimeError => error
        raise ProtocolError, error.message
      rescue ::Async::TimeoutError
        raise TimeoutError
      end
    end
  end
end

Redis::Connection.drivers << Redis::Connection::Async
