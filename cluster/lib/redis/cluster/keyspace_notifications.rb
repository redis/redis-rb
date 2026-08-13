# frozen_string_literal: true

require "uri"
require "redis/keyspace_notifications"
require "redis/cluster/keyspace_notifications/node_listener"

class Redis
  class Cluster
    # Keyspace/keyevent/subkey notification manager for Redis Cluster.
    #
    # In a cluster, keyspace notifications are node-local: each node emits events only
    # for the keys it owns and they are NOT forwarded on the cluster bus, so a plain
    # `subscribe`/`psubscribe` (which lands on a single node) silently receives only a
    # fraction of the events. This manager fans every subscription out to **all
    # primaries** (one dedicated pub/sub connection per primary), funnels the parsed
    # {Redis::KeyspaceNotifications::Notification} objects through one queue, and
    # invokes handlers serially on a single dispatcher thread — per-node ordering is
    # preserved, cross-node ordering is unspecified, and handlers need not be
    # thread-safe.
    #
    # Topology changes are handled reactively: a node connection error triggers a
    # {#refresh}, which re-enumerates the primaries via `CLUSTER SLOTS`, drops
    # listeners for vanished/demoted nodes and subscribes new primaries to every
    # registered pattern. There is no proactive polling — after intentionally adding
    # primaries (scale-out) call {#refresh} yourself, because a brand-new node emits
    # no error signal.
    #
    # Like all keyspace notifications, delivery is fire-and-forget: events emitted
    # while a node was unreachable are lost. In cluster mode `db` is always 0.
    class KeyspaceNotifications
      DEFAULT_QUEUE_SIZE = 1024

      # @param cluster [Redis::Cluster] the owning cluster client (used to enumerate
      #   primaries; its connections are not used for the subscriptions themselves)
      # @param base_options [Hash] the cluster client's options, used to derive the
      #   per-node sidecar connection options (auth, TLS, timeouts, driver)
      # @param error_handler [#call, nil] receives (error, node_key) for every
      #   background error; node_key is nil for dispatcher-level errors. Defaults to
      #   warning on $stderr
      # @param queue_size [Integer] bound of the shared dispatch queue; when handlers
      #   are slower than the notification rate, node reader threads block on the full
      #   queue, which back-pressures their sockets
      def initialize(cluster, base_options:, error_handler: nil, queue_size: DEFAULT_QUEUE_SIZE)
        @cluster = cluster
        @base_options = base_options.dup
        @error_handler = error_handler
        @registry = {} # pattern (BINARY String) => user handler (nil for default) — canonical truth
        @default_handler = nil
        @listeners = {} # "host:port" => NodeListener
        @queue = SizedQueue.new(queue_size)
        @lock = Monitor.new
        @refresh_lock = Mutex.new
        @closed = false
        @dispatcher = spawn_dispatcher
        refresh
      end

      # Subscribe to notification channel patterns on every primary (build them with
      # {Redis::KeyspaceNotifications::Channels}; remember `db` is always 0 in cluster).
      # Re-subscribing a known pattern replaces its handler. Per-node failures are
      # reported to the error handler and healed by the next {#refresh}; the registry
      # is always updated.
      #
      # @param patterns [Array<String>] channel names or psubscribe patterns
      # @param handler [#call, nil] receives each {Redis::KeyspaceNotifications::Notification};
      #   falls back to the {#on_notification} default handler when nil
      # @return [void]
      def subscribe(*patterns, handler: nil, &block)
        raise ArgumentError, "no patterns given" if patterns.empty?

        handler ||= block
        patterns = patterns.map { |pattern| pattern.to_s.b }
        @lock.synchronize do
          raise SubscriptionError, "keyspace notifications manager is closed" if @closed

          patterns.each { |pattern| @registry[pattern] = handler }
          each_listener_best_effort { |listener| listener.subscribe(patterns, handler) }
        end
        nil
      end

      # Unsubscribe patterns (everything when called without arguments) on every
      # primary. Unlike the standalone manager (which commits local state only after
      # the server's acknowledgment), tracking here is deliberately removed FIRST:
      # with N nodes a partial failure is normal, and if the registry kept the
      # pattern because one node failed, the next refresh would re-subscribe it on
      # the N-1 nodes that had already unsubscribed. Removing tracking first keeps
      # every healthy node correct immediately; a node whose unsubscribe failed is
      # reported to the error handler and converges on the next refresh, whose
      # per-node catch-up also removes patterns that are no longer registered.
      #
      # @param patterns [Array<String>]
      # @return [void]
      def unsubscribe(*patterns)
        patterns = patterns.map { |pattern| pattern.to_s.b }
        @lock.synchronize do
          patterns.empty? ? @registry.clear : patterns.each { |pattern| @registry.delete(pattern) }
          each_listener_best_effort { |listener| listener.unsubscribe(patterns) }
        end
        nil
      end

      # @!group Typed subscriptions (db is always 0 in cluster)

      # Watch every event happening to keys matching +key+ on all primaries.
      # @param key [String] key name or glob pattern
      def subscribe_keyspace(key = "*", &handler)
        subscribe(::Redis::KeyspaceNotifications::Channels.keyspace(key), handler: handler)
      end

      # Watch every key receiving events matching +event+ on all primaries.
      # @param event [String] event name (e.g. "expired") or glob pattern
      def subscribe_keyevent(event = "*", &handler)
        subscribe(::Redis::KeyspaceNotifications::Channels.keyevent(event), handler: handler)
      end

      # Watch subkey-level events on keys matching +key+ (Redis 8.8+, flag `S`).
      # @param key [String] key name or glob pattern
      def subscribe_subkeyspace(key = "*", &handler)
        subscribe(::Redis::KeyspaceNotifications::Channels.subkeyspace(key), handler: handler)
      end

      # Watch subkey-level events matching +event+ (Redis 8.8+, flag `T`).
      # @param event [String] event name (e.g. "hdel") or glob pattern
      def subscribe_subkeyevent(event = "*", &handler)
        subscribe(::Redis::KeyspaceNotifications::Channels.subkeyevent(event), handler: handler)
      end

      # Watch events on one exact key + subkey pair (Redis 8.8+, flag `I`).
      # @param key [String] key name (must not contain "\n")
      # @param subkey [String] subkey (e.g. hash field) or glob pattern
      def subscribe_subkeyspaceitem(key, subkey = "*", &handler)
        subscribe(::Redis::KeyspaceNotifications::Channels.subkeyspaceitem(key, subkey), handler: handler)
      end

      # Watch subkeys affected by +event+ on keys matching +key+ (Redis 8.8+, flag `V`).
      # @param event [String] event name or glob pattern
      # @param key [String] key name or glob pattern
      def subscribe_subkeyspaceevent(event = "*", key = "*", &handler)
        subscribe(::Redis::KeyspaceNotifications::Channels.subkeyspaceevent(event, key), handler: handler)
      end

      # @!endgroup

      # Default handler for notifications whose pattern has no dedicated handler.
      # @yieldparam notification [Redis::KeyspaceNotifications::Notification]
      def on_notification(&block)
        @lock.synchronize { @default_handler = block }
        nil
      end

      # Replaces the error handler. Receives (error, node_key); must not raise.
      def on_error(&block)
        @error_handler = block
        nil
      end

      # Reconcile the per-node listeners with the current set of primaries: drop
      # vanished/demoted/broken nodes, connect new primaries, and (re-)subscribe every
      # listener to every registered pattern (idempotent for already-subscribed nodes).
      # Runs automatically when a node connection error is reported; call it manually
      # after adding primaries to the cluster.
      #
      # @return [void]
      # @raise [Redis::Cluster::KeyspaceNotificationsRefreshError] when one or more
      #   primaries could not be subscribed (see its #errors for the per-node causes)
      def refresh
        @refresh_lock.synchronize do
          return if @closed

          primaries = current_primaries
          failures = {}
          @lock.synchronize do
            expect_subscribed = !@registry.empty?
            (@listeners.keys - primaries.keys).each { |node_key| @listeners.delete(node_key)&.close }

            primaries.each do |node_key, (host, port)|
              listener = @listeners[node_key]
              unless listener&.healthy?(expect_subscribed)
                @listeners.delete(node_key)&.close
                listener = nil
              end

              begin
                listener ||= @listeners[node_key] = NodeListener.new(
                  node_key, sidecar_options(host, port), @queue, on_error: method(:handle_node_error)
                )
                listener.catch_up(@registry)
              rescue StandardError => error
                failures[node_key] = error
                @listeners.delete(node_key)&.close
              end
            end
          end
          raise KeyspaceNotificationsRefreshError, failures unless failures.empty?
        end
        nil
      end

      # @return [Array<String>] "host:port" of every primary currently listened to
      def node_keys
        @lock.synchronize { @listeners.keys }
      end

      # @return [Array<String>] the registered patterns
      def patterns
        @lock.synchronize { @registry.keys }
      end

      # @return [Boolean] whether at least one pattern is registered and listeners are attached
      def subscribed?
        @lock.synchronize { !@registry.empty? && !@listeners.empty? }
      end

      # @return [Boolean]
      def closed?
        @closed
      end

      # Close every node listener, stop the dispatcher and release all connections.
      # Idempotent.
      #
      # @return [void]
      def close
        listeners = @lock.synchronize do
          return if @closed

          @closed = true
          @listeners.values.tap { @listeners.clear }
        end
        listeners.each(&:close)
        @queue.close
        @dispatcher.join(Redis::KeyspaceNotifications::Manager::DEFAULT_CLOSE_TIMEOUT) unless
          @dispatcher.equal?(Thread.current)
        nil
      end
      alias stop close

      private

      def current_primaries
        @cluster.cluster("slots")
                .map { |range| range["master"] }
                .uniq { |master| [master["ip"], master["port"]] }
                .to_h { |master| ["#{master['ip']}:#{master['port']}", [master["ip"], master["port"]]] }
      end

      CLUSTER_ONLY_OPTIONS = %i[
        nodes replica replica_affinity fixed_hostname connector concurrency
        connect_with_original_config max_startup_sample slow_command_timeout
      ].freeze
      private_constant :CLUSTER_ONLY_OPTIONS

      def sidecar_options(host, port)
        options = @base_options.reject { |key, _| CLUSTER_ONLY_OPTIONS.include?(key) }
        options.delete(:url)
        options.delete(:path)
        options.delete(:sentinels)
        options.delete(:name)
        options.delete(:role)
        # A single-endpoint TLS setup (fixed_hostname) must dial the FQDN, not the announced IP.
        host = @base_options[:fixed_hostname] if @base_options[:fixed_hostname]
        auth_from_nodes.merge(options).merge(host: host, port: Integer(port), db: 0)
      end

      # Top-level :username/:password are the supported way to authenticate; as a
      # convenience, credentials embedded in the first configured node URL are reused
      # for the sidecar connections when no top-level ones are given.
      def auth_from_nodes
        node = Array(@base_options[:nodes]).first
        case node
        when String
          uri = URI.parse(node)
          { username: uri.user, password: uri.password }.compact
        when Hash
          node.slice(:username, :password)
        else
          {}
        end
      rescue URI::InvalidURIError
        {}
      end

      def each_listener_best_effort
        @listeners.each do |node_key, listener|
          yield listener
        rescue StandardError => error
          report_error(error, node_key)
          request_refresh(node_key)
        end
      end

      # Called from node listener threads on every background error of a node.
      def handle_node_error(node_key, error)
        report_error(error, node_key)
        request_refresh(node_key)
      end

      def request_refresh(node_key)
        @queue.push([:node_failed, node_key, nil], true)
      rescue ThreadError, ClosedQueueError
        nil # queue full (a refresh request is effectively pending) or manager closed
      end

      def spawn_dispatcher
        thread = Thread.new do
          while (item = @queue.pop)
            kind, handler, notification = item
            case kind
            when :notification
              dispatch(handler, notification)
            when :node_failed
              begin
                refresh
              rescue StandardError => error
                report_error(error, nil)
              end
            end
          end
        end
        thread.name = "redis-cluster-keyspace-notifications"
        thread
      end

      def dispatch(handler, notification)
        handler ||= @lock.synchronize { @default_handler }
        handler&.call(notification)
      rescue StandardError => error
        report_error(error, nil)
      end

      def report_error(error, node_key)
        handler = @error_handler
        if handler
          handler.call(error, node_key)
        else
          warn("Redis cluster keyspace notifications error#{" (#{node_key})" if node_key}: " \
               "#{error.class}: #{error.message}")
        end
      rescue StandardError
        nil # a broken error handler must never kill the dispatcher
      end
    end
  end
end
