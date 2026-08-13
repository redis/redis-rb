# frozen_string_literal: true

class Redis
  class Cluster
    class KeyspaceNotifications
      # One cluster primary: owns a dedicated standalone connection and a core-layer
      # standalone manager whose listener thread forwards every parsed notification
      # into the cluster manager's shared dispatch queue. Reader threads never run
      # user code — handlers are invoked serially by the cluster dispatcher.
      class NodeListener
        # @return [String] "host:port" of the primary this listener is attached to
        attr_reader :node_key

        # @param node_key [String] "host:port"
        # @param redis_options [Hash] options for the sidecar ::Redis connection
        # @param queue [SizedQueue] the cluster manager's dispatch queue
        # @param on_error [#call] receives (node_key, error) for every background error
        def initialize(node_key, redis_options, queue, on_error:)
          @node_key = node_key
          @queue = queue
          @redis = ::Redis.new(redis_options)
          @manager = ::Redis::KeyspaceNotifications::Manager.new(
            redis: @redis,
            error_handler: ->(error) { on_error.call(node_key, error) }
          )
        end

        # Reconcile this node with the registry: subscribe every registered pattern
        # (idempotent — already-subscribed patterns are simply re-acked) and remove
        # any pattern the node is still subscribed to that is no longer registered
        # (e.g. a per-node unsubscribe failure that tracking-first removal left
        # behind). This is the per-node convergence step run by every refresh.
        #
        # @param registry [Hash{String => #call, nil}] pattern => user handler
        # @return [NodeListener] self
        def catch_up(registry)
          registry.each { |pattern, handler| subscribe([pattern], handler) }
          extra = @manager.patterns - registry.keys
          @manager.unsubscribe(*extra) unless extra.empty?
          self
        end

        # @param patterns [Array<String>]
        # @param handler [#call, nil] the user handler (resolved to the default at dispatch time when nil)
        def subscribe(patterns, handler)
          @manager.subscribe(*patterns, handler: enqueueing(handler))
        end

        # @param patterns [Array<String>] empty for "everything"
        def unsubscribe(patterns)
          @manager.unsubscribe(*patterns)
        end

        # Whether this listener needs no rebuild. When subscriptions are expected it
        # must be actively subscribed — a listener that is mid-reconnect or whose
        # reconnect budget ran out reports false and is rebuilt (and caught up) by
        # the refresh that is asking.
        #
        # @param expect_subscribed [Boolean] whether the cluster registry has patterns
        # @return [Boolean]
        def healthy?(expect_subscribed)
          return false if @manager.closed?

          !expect_subscribed || @manager.subscribed?
        end

        # Close the core manager (kills its listener thread) and the sidecar connection.
        def close
          @manager.close
        rescue StandardError
          nil
        end

        private

        # Wraps a user handler into a proc that pushes into the shared dispatch queue.
        # Runs on this node's listener thread; blocks when the queue is full, which
        # back-pressures this node's socket reads.
        def enqueueing(handler)
          lambda do |notification|
            @queue.push([:notification, handler, notification])
          rescue ClosedQueueError
            nil # the cluster manager closed concurrently; drop the notification
          end
        end
      end
    end
  end
end
