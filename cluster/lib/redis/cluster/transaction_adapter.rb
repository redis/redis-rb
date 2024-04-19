# frozen_string_literal: true

require 'redis_client/cluster/transaction'

class Redis
  class Cluster
    class TransactionAdapter < RedisClient::Cluster::Transaction
      def initialize(client, router, command_builder, node: nil, slot: nil, asking: false)
        @client = client
        super(router, command_builder, node: node, slot: slot, asking: asking)
      end

      def multi
        yield self
      end

      def exec
        # no need to do anything
      end

      def discard
        # no need to do anything
      end

      def watch(*_)
        # no need to do anything
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
  end
end
