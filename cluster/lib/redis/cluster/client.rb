# frozen_string_literal: true

require 'redis-cluster-client'

class Redis
  class Cluster
    class Client < RedisClient::Cluster
      ERROR_MAPPING = ::Redis::Client::ERROR_MAPPING.merge(
        RedisClient::Cluster::InitialSetupError => Redis::Cluster::InitialSetupError,
        RedisClient::Cluster::OrchestrationCommandNotSupported => Redis::Cluster::OrchestrationCommandNotSupported,
        RedisClient::Cluster::AmbiguousNodeError => Redis::Cluster::AmbiguousNodeError,
        RedisClient::Cluster::ErrorCollection => Redis::Cluster::CommandErrorCollection
      ).freeze

      class << self
        def config(**kwargs)
          super(protocol: 2, **kwargs)
        end

        def sentinel(**kwargs)
          super(protocol: 2, **kwargs)
        end
      end

      def initialize(*)
        handle_errors { super }
      end
      ruby2_keywords :initialize if respond_to?(:ruby2_keywords, true)

      def id
        @router.node.node_keys.join(' ')
      end

      def server_url
        @router.node.node_keys
      end

      def connected?
        true
      end

      def disable_reconnection
        yield # TODO: do we need this, is it doable?
      end

      def timeout
        config.read_timeout
      end

      def db
        0
      end

      undef_method :call
      undef_method :call_once
      undef_method :call_once_v
      undef_method :blocking_call

      def call_v(command, &block)
        handle_errors { super(command, &block) }
      end

      def blocking_call_v(timeout, command, &block)
        timeout += self.timeout if timeout && timeout > 0
        handle_errors { super(timeout, command, &block) }
      end

      def pipelined(&block)
        handle_errors { super(&block) }
      end

      def multi(&block)
        handle_errors { super(&block) }
      end

      private

      def handle_errors
        yield
      rescue RedisClient::Cluster::ErrorCollection => error
        error.errors.each do |_node, node_error|
          if node_error.is_a?(RedisClient::AuthenticationError)
            raise ERROR_MAPPING.fetch(node_error.class), node_error.message, node_error.backtrace
          end
        end
        raise ERROR_MAPPING.fetch(error.class), error.message, error.backtrace
      rescue ::RedisClient::Error => error
        raise ERROR_MAPPING.fetch(error.class), error.message, error.backtrace
      end
    end
  end
end
