require "eventmachine"
require "em-synchrony"
require "hiredis/reader"

class Redis
  module Connection

    class RedisClient < EM::Connection
      include EM::Deferrable

      def connection_completed
        p [:connection_completed]

        @in = nil
        @messages = []
        @reader = ::Hiredis::Reader.new

        succeed
      end

      def receive_data(data)
        p [:got, data]

        @reader.feed(data)
        until (reply = @reader.gets) == false
          @messages << reply
          @in.succeed @messages.shift if @in
        end

      end

      def read
        msg = @messages.shift || sync
      end

      def send(data)
        p [:send, data]
        callback { p [:sending, data]; send_data data }
      end

      def unbind
        p [:unbind]
        @messages.clear
        @in.fail if @in
        @in = nil
      end

      private

        def sync
          @in = EventMachine::DefaultDeferrable.new
          EventMachine::Synchrony.sync @in
        end

    end

    class Synchrony
      def initialize
        @timeout = 5
        @state = :disconnected
        @connection = nil
      end

      def connected?
        @state == :connected
      end

      def timeout=(usecs)
        @timeout = usecs
      end

      def connect(host, port, timeout)
        p [:connect, host, port, timeout]
        f = Fiber.current
        conn = EventMachine.connect(host, port, RedisClient) do |c|
          # c.connection_timeout = timeout
        end

        conn.callback do
          @connection = conn
          @state = :connected
          f.resume conn
        end

        conn.errback do
          @connection = conn
          f.resume conn
        end

        Fiber.yield
      end

      # def connect_unix(path, timeout)
      #   @connection.connect_unix(path, timeout)
      # rescue Errno::ETIMEDOUT
      #   raise Timeout::Error
      # end

      def disconnect
        @state = :disconnected
        # @connection.close_after_writing
        @connection = nil
      end

      COMMAND_DELIMITER = "\r\n"

      def write(command)
        @connection.send(build_command(*command).join(COMMAND_DELIMITER))
      end

      def build_command(*args)
        command = []
        command << "*#{args.size}"

        args.each do |arg|
          arg = arg.to_s
          command << "$#{string_size arg}"
          command << arg
        end

        # Trailing delimiter
        command << ""
        command
      end

      def read
        @connection.read
      rescue RuntimeError => err
        raise ::Redis::ProtocolError.new(err.message)
      end

      protected
      if "".respond_to?(:bytesize)
        def string_size(string)
          string.to_s.bytesize
        end
      else
        def string_size(string)
          string.to_s.size
        end
      end

      if defined?(Encoding::default_external)
        def encode(string)
          string.force_encoding(Encoding::default_external)
        end
      else
        def encode(string)
          string
        end
      end
    end
  end
end
