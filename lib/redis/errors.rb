class Redis
  # Base error for all redis-rb errors.
  class BaseError < RuntimeError
  end

  # Raised by the connection when a protocol error occurs.
  class ProtocolError < BaseError
    def initialize(reply_type)
      super(<<-EOS.gsub(/(?:^|\n)\s*/, " "))
        Got '#{reply_type}' as initial reply byte.
        If you're in a forking environment, such as Unicorn, you need to
        connect to Redis after forking.
      EOS
    end
  end

  # Raised by the client when command execution returns an error reply.
  class CommandError < BaseError
  end

  # Base error for connection related errors.
  class BaseConnectionError < BaseError
  end

  # Raised when connection to a Redis server cannot be made.
  class CannotConnectError < BaseConnectionError
  end

  # Raised when connection to a Redis server is lost.
  class ConnectionError < BaseConnectionError
  end

  # Raised when performing I/O times out.
  class TimeoutError < BaseConnectionError
  end

  # Raised when the connection was inherited by a child process.
  class InheritedError < BaseConnectionError
  end

  # Raised when there are no sentinels to connect to.
  class NotConnectedToSentinels < Redis::BaseConnectionError
  end

  # Raised when the master connection is down.
  class MasterIsDown < Redis::BaseConnectionError
    attr_accessor :host, :port
    def initialize(host, port, message = '')
      host = host
      port = port
      if message == ''
        message = "Master is down host: [#{host}] port: #{port}"
      end
      super(message)
    end
  end

  # Raised when no masters are available for the master connection.
  class NoAvailableMasters < Redis::BaseConnectionError
    def initialize(master_name)
      super("No available masters named #{master_name}")
    end
  end

end
