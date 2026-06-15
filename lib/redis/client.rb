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
      def config(protocol: 3, **kwargs)
        super(protocol: protocol, **kwargs)
      end

      def sentinel(protocol: 3, **kwargs)
        super(protocol: protocol, **kwargs, client_implementation: ::RedisClient)
      end

      def translate_error!(error, mapping: ERROR_MAPPING)
        redis_error = translate_error_class(error.class, mapping: mapping)
        raise redis_error, error.message, error.backtrace
      end

      # Whether +error+ raised during the connection handshake means the server can't speak RESP3
      # (so we should retry the connection as RESP2). Covers Redis < 6 (no HELLO command, surfaced
      # by redis-client as UnsupportedServer) and any server replying NOPROTO to `HELLO 3`.
      def resp3_unsupported?(error)
        error.is_a?(::RedisClient::UnsupportedServer) ||
          (error.is_a?(::RedisClient::CommandError) && error.message.include?("NOPROTO"))
      end

      # Pin the given config to RESP2 so subsequent (re)connects skip the `HELLO 3` handshake.
      def downgrade_to_resp2!(config)
        config.instance_variable_set(:@protocol, 2)
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

    def protocol
      config.protocol
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
      # We default to RESP3. Servers that don't support it reject the `HELLO 3` handshake — most
      # notably Redis < 6.0, which has no HELLO command at all (redis-client raises
      # UnsupportedServer), but also anything answering NOPROTO. Transparently fall back to RESP2
      # once, so those servers keep working without the user having to set `protocol: 2`.
      if config.protocol == 3 && self.class.resp3_unsupported?(error)
        self.class.downgrade_to_resp2!(config)
        retry
      end

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
