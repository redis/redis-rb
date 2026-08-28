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
        # @param on_reconnect [#call] receives (node_key) after the core manager
        #   re-established a lost connection and replayed its subscriptions
        def initialize(node_key, redis_options, queue, on_error:, on_reconnect:)
          @node_key = node_key
          @queue = queue
          # One shared wrapper for every pattern: it only enqueues; the user
          # handler is resolved from the cluster registry at dispatch time. A
          # full queue blocks this node's reads (backpressure).
          @enqueue = lambda do |notification|
            @queue.push(notification)
          rescue ClosedQueueError
            nil # the cluster manager closed concurrently; drop the notification
          end
          @redis = ::Redis.new(redis_options)
          @manager = ::Redis::KeyspaceNotifications::Manager.new(
            redis: @redis,
            error_handler: ->(error) { on_error.call(node_key, error) }
          )
          # The core manager announces its own successful reconnect replays; the
          # rebuild path (a refresh replacing a torn-down listener with a fresh
          # one) is announced by the refresh itself.
          @manager.on_reconnect { on_reconnect.call(node_key) }
        end

        # Per-node convergence step run by every refresh: subscribe every
        # registered pattern (idempotent) and remove leftovers that are no
        # longer registered.
        #
        # @param patterns [Array<String>] the registered patterns
        # @return [NodeListener] self
        def catch_up(patterns)
          subscribe(patterns) unless patterns.empty?
          # Compare against registered INTENT, not confirmations: a
          # registered-but-unconfirmed leftover would be resurrected by the
          # reconnect replay if reconciliation couldn't see it.
          extra = @manager.registered_patterns - patterns
          @manager.unsubscribe(*extra) unless extra.empty?
          self
        end

        # @param patterns [Array<String>]
        def subscribe(patterns)
          @manager.subscribe(*patterns, handler: @enqueue)
        end

        # @param patterns [Array<String>] never empty — an empty list would mean
        #   "everything" to the core manager and race concurrent subscriptions
        def unsubscribe(patterns)
          return if patterns.empty?

          @manager.unsubscribe(*patterns)
        end

        # Whether this listener needs no rebuild: with subscriptions expected it
        # must be actively subscribed (mid-reconnect or budget-exhausted
        # listeners report false and are rebuilt by the asking refresh).
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
      end
    end
  end
end
