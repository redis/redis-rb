# frozen_string_literal: true

require 'redis_client/cluster/transaction'

class Redis
  class Cluster
    class TransactionAdapter
      class Internal < RedisClient::Cluster::Transaction
        def initialize(client, router, command_builder, node: nil, slot: nil, asking: false)
          @client = client
          super(router, command_builder, node: node, slot: slot, asking: asking)
        end

        def multi
          raise(Redis::Cluster::TransactionConsistencyError, "Can't nest multi transaction")
        end

        def exec
          # no need to do anything
        end

        def discard
          # no need to do anything
        end

        def watch(*_)
          raise(Redis::Cluster::TransactionConsistencyError, "Can't use watch in a transaction")
        end

        def unwatch
          # no need to do anything
        end

        private

        def method_missing(name, *args, **kwargs, &block)
          return call(name, *args, **kwargs, &block) if @client.respond_to?(name)

          super
        end

        def respond_to_missing?(name, include_private = false)
          return true if @client.respond_to?(name)

          super
        end
      end

      def initialize(client, router, command_builder, node: nil, slot: nil, asking: false)
        @client = client
        @router = router
        @command_builder = command_builder
        @node = node
        @slot = slot
        @asking = asking
        @lock_released = false
      end

      def lock_released?
        @lock_released
      end

      def multi
        @lock_released = true
        transaction = Redis::Cluster::TransactionAdapter::Internal.new(
          @client, @router, @command_builder, node: @node, slot: @slot, asking: @asking
        )
        yield transaction
        transaction.execute
      end

      def exec
        # no need to do anything
      end

      def discard
        # no need to do anything
      end

      def watch(*_)
        raise(Redis::Cluster::TransactionConsistencyError, "Can't nest watch command if you use the cluster client")
      end

      def unwatch
        @lock_released = true
        @node.call('UNWATCH')
      end

      private

      def method_missing(name, *args, **kwargs, &block)
        return @client.public_send(name, *args, **kwargs, &block) if @client.respond_to?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        return true if @client.respond_to?(name)

        super
      end
    end
  end
end
