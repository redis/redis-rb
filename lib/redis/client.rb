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
        return true if error.is_a?(::RedisClient::UnsupportedServer)
        return true if error.is_a?(::RedisClient::CommandError) && error.message.include?("NOPROTO")

        # Redis::Cluster discovers its topology by connecting to each startup node. When those nodes
        # don't speak RESP3, redis-cluster-client collects the per-node failures and re-raises them
        # wrapped in an InitialSetupError, discarding the original error classes (see
        # RedisClient::Cluster::InitialSetupError.from_errors). Only the concatenated message
        # survives, so match it to still trigger the RESP2 fallback for pre-6.0 clusters. Guarded by
        # defined? because the cluster error class is only loaded with the redis-clustering gem.
        defined?(::RedisClient::Cluster::InitialSetupError) &&
          error.is_a?(::RedisClient::Cluster::InitialSetupError) &&
          (error.message.include?("NOPROTO") || error.message.include?("HELLO command"))
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

    # We default to RESP3. Servers that can't speak it reject the `HELLO 3` handshake (Redis < 6.0
    # has no HELLO at all; others answer NOPROTO). Re-raise those errors untranslated so they reach
    # Redis#with_protocol_fallback as RedisClient::Error and trigger a transparent rebuild as RESP2 —
    # the same path the sentinel and cluster clients already use. Everything else is translated to
    # the matching Redis::* error.
    def call_v(command, &block)
      super(command, &block)
    rescue ::RedisClient::Error => error
      raise if Client.resp3_unsupported?(error)

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
      raise if Client.resp3_unsupported?(error)

      Client.translate_error!(error)
    end

    def pipelined(exception: true)
      super
    rescue ::RedisClient::Error => error
      raise if Client.resp3_unsupported?(error)

      Client.translate_error!(error)
    end

    def multi(watch: nil)
      super
    rescue ::RedisClient::Error => error
      raise if Client.resp3_unsupported?(error)

      Client.translate_error!(error)
    end

    def inherit_socket!
      @inherit_socket = true
    end
  end
end
