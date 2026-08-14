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
        @refresh_cond = @lock.new_cond
        @refresh_lock = Mutex.new
        @refresh_needed = false
        @closed = false
        @dispatcher = spawn_dispatcher
        @refresher = spawn_refresher
        begin
          refresh
        rescue StandardError
          # A failed construction must not leak the background threads or any
          # listeners a partial refresh already created — the caller gets an
          # exception, not an object it could close.
          close
          raise
        end
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
        listeners = @lock.synchronize do
          raise SubscriptionError, "keyspace notifications manager is closed" if @closed

          patterns.each { |pattern| @registry[pattern] = handler }
          @listeners.to_a
        end
        # Called from inside a handler, this runs on the dispatcher thread: the
        # ack-blocking fan-out below could deadlock against node readers stuck on a
        # full queue (they can't read acks until the dispatcher drains). Defer the
        # fan-out to the refresher, which reconciles from the updated registry.
        return request_refresh(nil) if dispatcher_thread?

        # Fan out WITHOUT holding the lock: each per-node subscribe blocks on that
        # node's acknowledgment (seconds against a sick node) and must not stall
        # dispatch, refresh or close. A refresh racing this call reconciles from the
        # already-updated registry, and re-subscribing is idempotent (re-acked).
        each_listener_best_effort(listeners) { |listener| listener.subscribe(patterns) }
        # A concurrent unsubscribe's fan-out may have undone ours after the fact;
        # if any pattern is no longer registered, the refresher reconciles the nodes.
        request_refresh(nil) if @lock.synchronize { patterns.any? { |pattern| !@registry.key?(pattern) } }
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
        targets = nil
        listeners = @lock.synchronize do
          targets = patterns.empty? ? @registry.keys : patterns
          patterns.empty? ? @registry.clear : patterns.each { |pattern| @registry.delete(pattern) }
          @listeners.to_a
        end
        # In-handler calls defer the ack-blocking fan-out to the refresher, exactly
        # like #subscribe (the dispatcher must keep draining for acks to flow).
        return request_refresh(nil) if dispatcher_thread?

        # Tracking was removed first (see above); the ack-blocking fan-out happens
        # outside the lock for the same reasons as in #subscribe. Always the captured
        # targets — an empty pattern list would mean "everything" at the node level
        # and also drop patterns a concurrent subscribe added after our capture.
        each_listener_best_effort(listeners) { |listener| listener.unsubscribe(targets) }
        # A concurrent subscribe may have re-registered one of these patterns and had
        # its node subscriptions undone by our fan-out; the refresher reconciles.
        request_refresh(nil) if @lock.synchronize { targets.any? { |pattern| @registry.key?(pattern) } }
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
      # The key is treated literally — glob metacharacters in it are escaped, since
      # every manager subscription is a psubscribe pattern — while the subkey keeps
      # its documented glob behavior.
      # @param key [String] key name (must not contain "\n")
      # @param subkey [String] subkey (e.g. hash field) or glob pattern
      def subscribe_subkeyspaceitem(key, subkey = "*", &handler)
        channels = ::Redis::KeyspaceNotifications::Channels
        subscribe(channels.subkeyspaceitem(channels.glob_escape(key), subkey), handler: handler)
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
          if primaries.empty?
            # A cluster that answers CLUSTER SLOTS with no slot owners (mid-reset, or
            # a degraded node's view) is not a topology to reconcile against: tearing
            # every listener down would leave nothing to emit the connection errors
            # that drive reactive recovery. Keep the current listeners and raise —
            # the refresher's backoff loop (or the caller) retries.
            raise KeyspaceNotificationsRefreshError.new(
              {}, "CLUSTER SLOTS reported no primaries; keeping existing listeners"
            )
          end

          failures = {}

          # Prune vanished/demoted/unhealthy listeners under the lock; the
          # ack-blocking catch-ups below run WITHOUT it so dispatch and the API stay
          # responsive (close cannot interleave — it is excluded by @refresh_lock).
          stale = @lock.synchronize do
            expect_subscribed = !@registry.empty?
            gone = (@listeners.keys - primaries.keys).map { |node_key| @listeners.delete(node_key) }
            primaries.each_key do |node_key|
              listener = @listeners[node_key]
              gone << @listeners.delete(node_key) if listener && !listener.healthy?(expect_subscribed)
            end
            gone
          end
          stale.compact.each(&:close)

          primaries.each do |node_key, (host, port)|
            listener = @lock.synchronize { @listeners[node_key] }
            begin
              unless listener
                listener = NodeListener.new(
                  node_key, sidecar_options(host, port), @queue, on_error: method(:handle_node_error)
                )
                # Committed before catch-up so a racing subscribe fans out to this
                # node too — between that and the registry snapshot below, a pattern
                # registered mid-refresh is covered either way (both are idempotent).
                @lock.synchronize { @listeners[node_key] = listener }
              end
              # Converge on the LIVE registry: a subscribe/unsubscribe completing
              # between the snapshot and the catch-up would otherwise be undone by
              # the stale snapshot (e.g. re-subscribing a just-unsubscribed pattern)
              # with no later signal to correct it. Loop until a pass ran against an
              # unchanged registry; churn during a refresh is rare, so the bound is
              # a livelock guard, not an expected path.
              snapshot = @lock.synchronize { @registry.keys }
              converged = false
              5.times do
                listener.catch_up(snapshot)
                current = @lock.synchronize { @registry.keys }
                if current == snapshot
                  converged = true
                  break
                end

                snapshot = current
              end
              # Bound exhausted with the registry still churning: never accept a
              # possibly-stale node silently — the concurrent operations that kept
              # changing the registry saw it already updated and requested no refresh
              # themselves, so schedule the next reconciliation here.
              request_refresh(nil) unless converged
            rescue StandardError => error
              failures[node_key] = error
              @lock.synchronize { @listeners.delete(node_key) }&.close
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
        # Serialized with refresh via @refresh_lock: otherwise a refresh past its
        # own closed-check could recreate subscribed listeners on a manager that
        # close just tore down, leaking their threads and connections.
        @refresh_lock.synchronize do
          listeners = @lock.synchronize do
            return if @closed

            @closed = true
            @refresh_cond.broadcast # wake the refresher (idle or in backoff) so it exits
            @listeners.values.tap { @listeners.clear }
          end
          listeners.each(&:close)
          @queue.close
        end
        join_timeout = Redis::KeyspaceNotifications::Manager::DEFAULT_CLOSE_TIMEOUT
        # Same guard for both: close may be invoked from a handler (dispatcher) or
        # from an error handler fired by a failed reactive refresh (refresher), and
        # a self-join raises ThreadError.
        @refresher.join(join_timeout) unless @refresher.equal?(Thread.current)
        @dispatcher.join(join_timeout) unless @dispatcher.equal?(Thread.current)
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
        nodes replica replica_affinity fixed_hostname concurrency
        connect_with_original_config max_startup_sample slow_command_timeout
        command_routings
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
        connection_options_from_nodes.merge(options).merge(host: host, port: Integer(port), db: 0)
      end

      # Top-level :username/:password/:ssl are the supported way to configure the
      # connection; as a convenience, credentials and the TLS scheme embedded in the
      # first configured node (a `rediss://` URL, or Hash keys) are reused for the
      # sidecar connections when no top-level equivalents are given — the node list
      # is often the only place they exist.
      def connection_options_from_nodes
        node = Array(@base_options[:nodes]).first
        case node
        when String
          uri = URI.parse(node)
          # An exact mirror of redis-cluster-client's parse_node_url (cluster_config.rb):
          # the sidecars must authenticate with byte-identical credentials to the
          # cluster client's own node connections, whatever that parser's quirks —
          # including form-style decoding (`+` becomes a space there too). Diverging
          # toward stricter URI semantics here would make sidecars fail against
          # clusters that connect fine today; such a change belongs upstream, where
          # both sides would inherit it together.
          {
            username: uri.user ? URI.decode_www_form_component(uri.user) : nil,
            password: uri.password ? URI.decode_www_form_component(uri.password) : nil,
            ssl: uri.scheme == "rediss"
          }.reject { |_, value| value.nil? || value == "" || value == false }
        when Hash
          node.slice(:username, :password, :ssl)
        else
          {}
        end
      rescue URI::InvalidURIError
        {}
      end

      def each_listener_best_effort(listeners)
        listeners.each do |node_key, listener|
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

      def request_refresh(_node_key)
        @lock.synchronize do
          @refresh_needed = true
          @refresh_cond.broadcast
        end
        nil
      end

      def dispatcher_thread?
        Thread.current.equal?(@dispatcher)
      end

      def spawn_dispatcher
        thread = Thread.new do
          while (notification = @queue.pop)
            # Buffered items surviving a close are dropped, not dispatched: callers
            # may have torn down handler dependencies the moment close returned.
            dispatch(notification) unless @closed
          end
        end
        thread.name = "redis-cluster-keyspace-notifications"
        thread
      end

      # Reactive refreshes run on their own thread, NOT on the dispatcher: during a
      # refresh the dispatcher keeps draining the queue, so node reader threads
      # blocked on a full queue get unblocked and can process the subscription acks
      # the refresh is waiting for — running both roles on one thread deadlocks
      # under backpressure until the ack timeouts fire. The thread also owns the
      # failure-retry state: a failed reactive refresh reschedules itself with
      # exponential backoff, because the signal was already consumed and a
      # partially-rebuilt node may have no listener thread left to emit a new one.
      def spawn_refresher
        thread = Thread.new do
          retry_delay = nil
          loop do
            @lock.synchronize do
              @refresh_cond.wait_until { @refresh_needed || @closed }
              break if @closed

              @refresh_needed = false
            end
            break if @closed

            begin
              refresh
              retry_delay = nil
            rescue StandardError => error
              report_error(error, nil)
              retry_delay = [(retry_delay || 0.25) * 2, 30.0].min
              @lock.synchronize do
                @refresh_needed = true
                # Doubles as an interruptible backoff sleep: an incoming
                # request_refresh or close broadcast cuts it short.
                @refresh_cond.wait(retry_delay) unless @closed
              end
            end
          end
        end
        thread.name = "redis-cluster-keyspace-notifications-refresher"
        thread
      end

      # The handler is resolved from the live registry at dispatch time (queue items
      # carry only the notification): buffered events honor unsubscribes and handler
      # replacements that completed while they were queued, and events for patterns
      # no longer registered are dropped rather than leaked to a stale handler.
      def dispatch(notification)
        key = notification.pattern&.b
        handler = @lock.synchronize do
          @registry.key?(key) ? (@registry[key] || @default_handler) : nil
        end
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
