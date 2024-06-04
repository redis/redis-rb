# frozen_string_literal: true

require 'redis-cluster-client'
require 'redis/cluster/transaction_adapter'

class Redis
  class Cluster
    class Client < RedisClient::Cluster
      ERROR_MAPPING = ::Redis::Client::ERROR_MAPPING.merge(
        RedisClient::Cluster::InitialSetupError => Redis::Cluster::InitialSetupError,
        RedisClient::Cluster::OrchestrationCommandNotSupported => Redis::Cluster::OrchestrationCommandNotSupported,
        RedisClient::Cluster::AmbiguousNodeError => Redis::Cluster::AmbiguousNodeError,
        RedisClient::Cluster::ErrorCollection => Redis::Cluster::CommandErrorCollection,
        RedisClient::Cluster::Transaction::ConsistencyError => Redis::Cluster::TransactionConsistencyError,
        RedisClient::Cluster::NodeMightBeDown => Redis::Cluster::NodeMightBeDown,
      )

      class << self
        def config(**kwargs)
          super(protocol: 2, **kwargs)
        end

        def sentinel(**kwargs)
          super(protocol: 2, **kwargs)
        end

        def translate_error!(error, mapping: ERROR_MAPPING)
          case error
          when RedisClient::Cluster::ErrorCollection
            error.errors.each do |_node, node_error|
              if node_error.is_a?(RedisClient::AuthenticationError)
                raise mapping.fetch(node_error.class), node_error.message, node_error.backtrace
              end
            end

            remapped_node_errors = error.errors.map do |node_key, node_error|
              remapped = mapping.fetch(node_error.class, node_error.class).new(node_error.message)
              remapped.set_backtrace node_error.backtrace
              [node_key, remapped]
            end.to_h

            raise(Redis::Cluster::CommandErrorCollection.new(remapped_node_errors, error.message).tap do |remapped|
              remapped.set_backtrace error.backtrace
            end)
          else
            Redis::Client.translate_error!(error, mapping: mapping)
          end
        end
      end

      def initialize(*)
        handle_errors { super }
      end
      ruby2_keywords :initialize if respond_to?(:ruby2_keywords, true)

      def id
        server_url.join(' ')
      end

      def server_url
        @router.nil? ? @config.startup_nodes.keys : router.node_keys
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

      def pipelined(exception: true, &block)
        handle_errors { super(exception: exception, &block) }
      end

      def multi(watch: nil, &block)
        handle_errors { super(watch: watch, &block) }
      end

      def watch(*keys, &block)
        unless block_given?
          raise(
            Redis::Cluster::TransactionConsistencyError,
            'A block is required if you use the cluster client.'
          )
        end

        unless block.arity == 1
          raise(
            Redis::Cluster::TransactionConsistencyError,
            'Given block needs an argument if you use the cluster client.'
          )
        end

        handle_errors do
          RedisClient::Cluster::OptimisticLocking.new(router).watch(keys) do |c, slot, asking|
            transaction = Redis::Cluster::TransactionAdapter.new(
              self, router, @command_builder, node: c, slot: slot, asking: asking
            )

            result = yield transaction
            c.call('UNWATCH') unless transaction.lock_released?
            result
          end
        end
      end

      private

      def handle_errors
        yield
      rescue ::RedisClient::Error => error
        Redis::Cluster::Client.translate_error!(error)
      end
    end
  end
end
