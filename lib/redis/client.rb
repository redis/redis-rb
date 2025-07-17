# frozen_string_literal: true

class Redis
  class Client < ::RedisClient
    ERROR_MAPPING = {
      RedisClient::ConnectionError => Redis::ConnectionError,
      RedisClient::CommandError => Redis::CommandError,
      RedisClient::ReadTimeoutError => Redis::TimeoutError,
      RedisClient::CannotConnectError => Redis::CannotConnectError,
      RedisClient::AuthenticationError => Redis::CannotConnectError,
      RedisClient::FailoverError => Redis::CannotConnectError,
      RedisClient::PermissionError => Redis::PermissionError,
      RedisClient::WrongTypeError => Redis::WrongTypeError,
      RedisClient::ReadOnlyError => Redis::ReadOnlyError,
      RedisClient::ProtocolError => Redis::ProtocolError,
      RedisClient::OutOfMemoryError => Redis::OutOfMemoryError,
    }
    if defined?(RedisClient::NoScriptError)
      ERROR_MAPPING[RedisClient::NoScriptError] = Redis::NoScriptError
    end

    class << self
      def config(**kwargs)
        super(protocol: 2, **kwargs)
      end

      def sentinel(**kwargs)
        super(protocol: 2, **kwargs, client_implementation: ::RedisClient)
      end

      def translate_error!(error, mapping: ERROR_MAPPING)
        redis_error = translate_error_class(error.class, mapping: mapping)
        raise redis_error, error.message, error.backtrace
      end

      private

      def translate_error_class(error_class, mapping: ERROR_MAPPING)
        mapping.fetch(error_class)
      rescue IndexError
        if (client_error = error_class.ancestors.find { |a| mapping[a] })
          mapping[error_class] = mapping[client_error]
        else
          raise
        end
      end
    end

    def id
      config.id
    end

    def server_url
      config.server_url
    end

    def timeout
      config.read_timeout
    end

    def db
      config.db
    end

    def host
      config.host unless config.path
    end

    def port
      config.port unless config.path
    end

    def path
      config.path
    end

    def username
      config.username
    end

    def password
      config.password
    end

    undef_method :call
    undef_method :call_once
    undef_method :call_once_v
    undef_method :blocking_call

    def ensure_connected(retryable: true, &block)
      super(retryable: retryable, &block)
    rescue ::RedisClient::Error => error
      Client.translate_error!(error)
    end

    def call_v(command, &block)
      super(command, &block)
    rescue ::RedisClient::Error => error
      Client.translate_error!(error)
    end

    def blocking_call_v(timeout, command, &block)
      if timeout && timeout > 0
        # Can't use the command timeout argument as the connection timeout
        # otherwise it would be very racy. So we add the regular read_timeout on top
        # to account for the network delay.
        timeout += config.read_timeout
      end

      super(timeout, command, &block)
    rescue ::RedisClient::Error => error
      Client.translate_error!(error)
    end

    def pipelined(exception: true)
      super
    rescue ::RedisClient::Error => error
      Client.translate_error!(error)
    end

    def multi(watch: nil)
      super
    rescue ::RedisClient::Error => error
      Client.translate_error!(error)
    end

    def inherit_socket!
      @inherit_socket = true
    end
  end
end
