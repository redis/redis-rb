# frozen_string_literal: true

require "uri"
require "redis/keyspace_notifications"
require "redis/cluster/keyspace_notifications/node_listener"

class Redis
  class Cluster
    # Keyspace/keyevent/subkey notification manager for Redis Cluster.
    #
    # In a cluster, keyspace notifications are node-local (not forwarded on the
    # cluster bus), so a plain subscribe on one node silently receives only a
    # fraction of the events. This manager fans every subscription out to **all
    # primaries** (one dedicated pub/sub connection each), funnels the parsed
    # {Redis::KeyspaceNotifications::Notification} objects through one queue, and
    # invokes handlers serially on a single dispatcher thread — per-node ordering
    # is preserved, cross-node ordering is unspecified, handlers need not be
    # thread-safe.
    #
    # Topology changes are handled reactively: a node connection error triggers a
    # {#refresh}, which re-enumerates the primaries via `CLUSTER NODES` (membership,
    # not slot coverage — a scale-out primary is discovered before it owns a slot),
    # drops vanished/demoted nodes and subscribes new primaries to every registered
    # pattern. There is no proactive polling — after adding primaries call
    # {#refresh} yourself before resharding, since a brand-new node emits no error
    # signal.
    #
    # Like all keyspace notifications, delivery is fire-and-forget: events emitted
    # while a node was unreachable are lost. Duplicates are possible too: a primary
    # demoted WITHOUT its connections dropping (e.g. a manual `CLUSTER FAILOVER`)
    # emits no error signal, and as a replica it re-emits every replicated write
    # until a {#refresh} observes the settled topology and prunes it. Handlers
    # should tolerate both. In cluster mode `db` is always 0.
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
        @reconnect_handler = nil
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
          # listeners a partial refresh already created.
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
      # @raise [Redis::CommandError] when the server rejects a pattern (e.g. an
      #   ACL-forbidden channel): the rejected pattern is evicted from the registry
      #   — it could never succeed and would poison every future refresh — while
      #   the call's other patterns stay registered
      def subscribe(*patterns, handler: nil, &block)
        raise ArgumentError, "no patterns given" if patterns.empty?

        handler ||= block
        patterns = patterns.map { |pattern| pattern.to_s.b }
        listeners = @lock.synchronize do
          raise SubscriptionError, "keyspace notifications manager is closed" if @closed

          patterns.each { |pattern| @registry[pattern] = handler }
          @listeners.to_a
        end
        # In-handler calls run on the dispatcher thread: an ack-blocking fan-out
        # would deadlock against node readers stuck on a full queue. Defer to the
        # refresher, which reconciles from the already-updated registry.
        return request_refresh(nil) if dispatcher_thread?

        # Fan out WITHOUT holding the lock (each per-node subscribe blocks on that
        # node's ack). One pattern per call: under the core manager's rejection
        # attribution a CommandError raised here names THIS pattern, so the
        # culprit is identified directly — no probing pass racing the reactive
        # refresh's prune-and-rebuild.
        rejected = {}
        failures = {}
        listeners.each do |node_key, listener|
          patterns.each do |pattern|
            listener.subscribe([pattern])
          rescue ::Redis::CommandError => error
            # Deterministic server rejection: left registered, it would fail
            # every future catch-up on every primary. Evicted below, then raised.
            rejected[pattern] ||= error
          end
        rescue StandardError => error
          failures[node_key] = error
        end
        unless rejected.empty?
          # Unconditional delete: the server rejects by pattern name, so a
          # concurrent re-registration is just as poisoned. The refresher's
          # catch-up unsubscribes nodes that accepted an evicted pattern.
          @lock.synchronize { rejected.each_key { |pattern| @registry.delete(pattern) } }
        end
        # Every failed node is reported individually and healed by the refresher.
        failures.each { |node_key, error| report_error(error, node_key) }
        request_refresh(nil) unless rejected.empty? && failures.empty?
        raise rejected.values.first unless rejected.empty?

        # Reconcile via the refresher when the fan-out could not have done the
        # job: no listeners at all (no connections = no error signal), or a
        # concurrent unsubscribe undid ours after the fact.
        if listeners.empty? || @lock.synchronize { patterns.any? { |pattern| !@registry.key?(pattern) } }
          request_refresh(nil)
        end
        # A close racing this call tore the listeners down after our snapshot:
        # returning success would lie about a subscription on a closed manager.
        raise SubscriptionError, "keyspace notifications manager is closed" if closed?

        nil
      end

      # Unsubscribe patterns (everything when called without arguments) on every
      # primary. Unlike the standalone manager, tracking is removed FIRST: with N
      # nodes a partial failure is normal, and keeping the pattern registered for
      # one failed node would make the next refresh re-subscribe it on the N-1
      # nodes that already unsubscribed. A node whose unsubscribe failed is
      # reported and converges on the next refresh.
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
        # Nothing registered: an empty fan-out would mean "everything" at the
        # node level and wipe patterns a concurrent subscribe just installed.
        return if targets.empty?

        # In-handler calls defer the ack-blocking fan-out, like #subscribe.
        return request_refresh(nil) if dispatcher_thread?

        # Always the captured targets — an empty list would mean "everything" at
        # the node level and drop patterns added after our capture.
        each_listener_best_effort(listeners) { |listener| listener.unsubscribe(targets) }
        # A concurrent subscribe may have re-registered a target and had its node
        # subscriptions undone by our fan-out; the refresher reconciles.
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
        # Synchronized for the happens-before edge non-GVL runtimes need.
        @lock.synchronize { @error_handler = block }
        nil
      end

      # Called with the node_key after a node's subscriptions were (re-)established
      # following a gap — its listener reconnected on its own, a refresh rebuilt
      # it, or a refresh attached a primary not listened to before (a promoted
      # replica under a new address, or a scale-out node). Notifications the node
      # emitted during the gap are lost; use this to reconcile. The callback may
      # fire more than once per gap, runs on a background thread, and should be
      # fast and must not raise.
      def on_reconnect(&block)
        @lock.synchronize { @reconnect_handler = block }
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
      #   primaries could not be subscribed (see its #errors for the per-node causes).
      #   Called from inside a notification handler, the reconciliation is instead
      #   deferred to the background refresher and nothing is raised
      def refresh
        # In-handler calls run on the dispatcher thread: the ack-blocking
        # catch-ups would deadlock against node readers stuck on a full queue.
        return request_refresh(nil) if dispatcher_thread?

        # Reports and reconnect announcements are delivered only after the
        # refresh lock is released (see ensure): the error handler is user code
        # that may call #close or #refresh, which need this non-reentrant lock.
        deferred_reports = []
        deferred_reconnects = []
        @refresh_lock.synchronize do
          return if closed?

          # Raises (keeping existing listeners) on a view that is not a topology
          # to reconcile against.
          primaries = current_primaries

          failures = {}

          # Prune vanished/demoted/unhealthy listeners under the lock; the
          # ack-blocking catch-ups below run without it so dispatch and the API
          # stay responsive.
          stale = @lock.synchronize do
            expect_subscribed = !@registry.empty?
            gone_keys = @listeners.keys - primaries.keys
            primaries.each_key do |node_key|
              listener = @listeners[node_key]
              gone_keys << node_key if listener && !listener.healthy?(expect_subscribed)
            end
            gone_keys.map { |node_key| @listeners.delete(node_key) }
          end
          # In parallel, like #close: each close joins that node's threads, and a
          # serial prune would hold @refresh_lock for O(nodes) while #close
          # waits on it unboundedly.
          stale.compact.map { |listener| Thread.new { listener.close } }.each(&:join)

          # Failure-path listeners are detached in the loop but closed together
          # (in parallel) afterwards — the same O(nodes) stall argument.
          doomed = []
          primaries.each do |node_key, (host, port)|
            # A racing close raises @closed first, then waits on @refresh_lock:
            # abort at the node boundary instead of sitting out every remaining
            # catch-up.
            break if closed?

            listener = @lock.synchronize { @listeners[node_key] }
            created = false
            begin
              unless listener
                created = true
                listener = NodeListener.new(
                  node_key, sidecar_options(host, port), @queue,
                  on_error: method(:handle_node_error), on_reconnect: method(:handle_node_reconnect)
                )
                # Committed before catch-up so a racing subscribe fans out to
                # this node too (both are idempotent).
                @lock.synchronize { @listeners[node_key] = listener }
              end
              # Converge on the LIVE registry: a subscribe/unsubscribe completing
              # between snapshot and catch-up would otherwise be undone with no
              # later signal to correct it. The bound is a livelock guard.
              snapshot = @lock.synchronize { @registry.keys }
              converged = false
              5.times do
                break if closed?

                begin
                  listener.catch_up(snapshot)
                rescue ::Redis::CommandError
                  # A server rejection is deterministic, NOT a node failure: the
                  # generic handling would delete every listener (all primaries
                  # reject the same pattern) and loop the refresher forever.
                  # Evict the culprit(s); an unattributable failure re-raises
                  # into the per-node failure handling.
                  raise if evict_rejected(listener, node_key, snapshot, reports: deferred_reports).empty?
                end
                current = @lock.synchronize { @registry.keys }
                if current == snapshot
                  converged = true
                  break
                end

                snapshot = current
              end
              # Registry still churning at the bound: schedule the next
              # reconciliation rather than accept a possibly-stale node silently.
              request_refresh(nil) unless converged || closed?
              # A NEWLY ATTACHED listener converged with patterns registered:
              # announce the gap's end (deferred — user code never runs under the
              # refresh lock). Keying on creation covers rebuilt listeners,
              # promoted replicas under a new node_key, and scale-out primaries.
              deferred_reconnects << node_key if created && converged && !snapshot.empty?
            rescue StandardError => error
              failures[node_key] = error
              # The gap is announced by the refresh that eventually re-creates
              # the node. The detached listener runs until the deferred close.
              doomed << @lock.synchronize { @listeners.delete(node_key) }
            end
          end
          doomed.compact.map { |listener| Thread.new { listener.close } }.each(&:join)
          # An aborted (closing) refresh reports nothing: close is tearing the
          # remaining listeners down right behind this lock.
          raise KeyspaceNotificationsRefreshError, failures unless failures.empty? || closed?
        end
        nil
      ensure
        # Checked per item: a concurrent close can complete mid-loop, and
        # callbacks that haven't started by then are dropped, not delivered (one
        # already running can still finish — the same bounded exposure as a
        # mid-flight handler outliving close).
        deferred_reports&.each { |error, node_key| report_error(error, node_key) unless closed? }
        deferred_reconnects&.each { |node_key| handle_node_reconnect(node_key) unless closed? }
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
        # Synchronized for the happens-before edge non-GVL runtimes need.
        @lock.synchronize { @closed }
      end

      # Close every node listener, stop the dispatcher and release all connections.
      # Idempotent.
      #
      # @return [void]
      def close
        # @closed is raised BEFORE waiting on @refresh_lock: an in-flight refresh
        # aborts at its next node boundary once the flag is up, so the wait below
        # ends promptly without skipping the teardown.
        @lock.synchronize do
          @closed = true
          @refresh_cond.broadcast # wake the refresher (idle or in backoff) so it exits
        end
        # Still serialized with refresh: otherwise a refresh past its closed
        # checks could recreate listeners on a torn-down manager.
        @refresh_lock.synchronize do
          listeners = @lock.synchronize { @listeners.values.tap { @listeners.clear } }
          # Queue first: node readers blocked pushing into a full queue are stuck
          # in Ruby, not I/O — only ClosedQueueError frees them.
          @queue.close
          # In parallel: serial teardown would make close O(nodes).
          listeners.map { |listener| Thread.new { listener.close } }.each(&:join)
        end
        join_timeout = Redis::KeyspaceNotifications::Manager::DEFAULT_CLOSE_TIMEOUT
        # close may run on the dispatcher (in-handler) or the refresher (error
        # handler of a failed reactive refresh); a self-join raises ThreadError.
        @refresher.join(join_timeout) unless @refresher.equal?(Thread.current)
        @dispatcher.join(join_timeout) unless @dispatcher.equal?(Thread.current)
        nil
      end
      alias stop close

      private

      def current_primaries
        # CLUSTER NODES rather than CLUSTER SLOTS: membership output lists
        # zero-slot primaries too, so a scale-out node gets its listener before
        # the first migrated key arrives (slots moving in emit no error signal).
        masters, dropped = @cluster.cluster("nodes").partition do |node|
          flags = node["flags"]
          # "fail?" (suspected) is kept — its slots are still assigned to it;
          # confirmed-failed, addressless and handshaking nodes are dropped.
          flags.include?("master") && (flags & %w[fail noaddr handshake]).empty?
        end
        # A dropped master still owning slots is a mid-failover view: reconciling
        # against it would succeed with N-1 listeners and stop the refresher's
        # retries, silently missing the promoted primary. Raise and retry.
        if dropped.any? { |node| node["flags"].include?("master") && node["slots"] }
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES reports a failed primary still owning slots " \
                "(failover in progress); keeping existing listeners"
          )
        end
        # No slot-owning primary at all (mid-reset, or a degraded node's view):
        # tearing everything down would leave nothing to emit the connection
        # errors that drive reactive recovery. Raise and retry.
        if masters.none? { |node| node["slots"] }
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES reported no slot-owning primaries; keeping existing listeners"
          )
        end

        # "ip:port@cport" (a ",hostname" may trail the cport since Redis 7);
        # rpartition keeps a bare IPv6 address's own colons intact.
        addresses = masters.map { |node| node["ip_port"].split("@", 2).first.rpartition(":").values_at(0, 2) }
        # Concealed endpoints announce empty addresses (clients are meant to
        # reuse existing connection info, which per-node sidecars cannot do).
        # Unless fixed_hostname supplies the dial target, fail loudly.
        if !@base_options[:fixed_hostname] && addresses.any? { |ip, _| ip.nil? || ip.empty? }
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES conceals node endpoints; per-node notification " \
                "sidecars need reachable addresses (or the fixed_hostname option)"
          )
        end

        # Distinct primaries collapsing onto one dial target: one sidecar cannot
        # listen to them all — fail loudly instead of silently dropping the rest.
        # Keyed on the EFFECTIVE dial target, not the announced address:
        # fixed_hostname replaces the host at connect time, so primaries
        # differing only by IP collapse onto one "hostname:port".
        fixed_hostname = @base_options[:fixed_hostname]
        dial_targets = addresses.map { |ip, port| "#{fixed_hostname || ip}:#{port}" }.uniq
        if dial_targets.size < masters.size
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES reports #{masters.size} primaries but only " \
                "#{dial_targets.size} distinguishable endpoints; per-node notification " \
                "sidecars need a unique address per primary"
          )
        end
        addresses.to_h { |ip, port| ["#{ip}:#{port}", [ip, port]] }
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
        # Transport retries forced OFF: each sidecar's core manager owns its
        # reconnection schedule, so a cluster-level retry ladder must not run
        # inside every sidecar connect attempt too.
        connection_options_from_nodes.merge(options)
                                     .merge(host: host, port: Integer(port), db: 0, reconnect_attempts: 0)
      end

      # Top-level :username/:password/:ssl are the supported configuration; as a
      # convenience, credentials and TLS embedded in the first configured node
      # (a `rediss://` URL, or Hash keys) are reused for the sidecars — the node
      # list is often the only place they exist.
      def connection_options_from_nodes
        node = Array(@base_options[:nodes]).first
        case node
        when String
          options_from_node_url(node)
        when Hash
          # Pass everything through except the seed's addressing (:host/:port/
          # :url/:path) — sidecars dial the discovered primaries. Explicit keys
          # override what the :url says.
          url_options = node[:url] ? options_from_node_url(node[:url]) : {}
          url_options.merge(node.except(:host, :port, :url, :path))
        else
          {}
        end
      rescue URI::InvalidURIError
        {}
      end

      # Mirrors redis-cluster-client's parse_node_url (including its form-style
      # decoding): the sidecars must authenticate with byte-identical credentials
      # to the cluster client's own node connections. Stricter URI semantics
      # would belong upstream, where both sides inherit them together.
      def options_from_node_url(url)
        uri = URI.parse(url)
        {
          username: uri.user ? URI.decode_www_form_component(uri.user) : nil,
          password: uri.password ? URI.decode_www_form_component(uri.password) : nil,
          ssl: uri.scheme == "rediss"
        }.reject { |_, value| value.nil? || value == "" || value == false }
      end

      def each_listener_best_effort(listeners)
        listeners.each do |node_key, listener|
          yield listener
        rescue StandardError => error
          report_error(error, node_key)
          request_refresh(node_key)
        end
      end

      # A CommandError from a batch subscribe means the server rejected one of
      # the patterns — deterministically, so it must not stay registered.
      # Identify the culprit(s) by subscribing one pattern at a time, evict them
      # from the registry, report each. Returns the rejected patterns mapped to
      # their errors; empty when the failure was not attributable to any single
      # pattern. With +reports+ (the refresh path) rejections are collected there
      # instead — the error handler must never run under the refresh lock.
      def evict_rejected(listener, node_key, patterns, reports: nil)
        rejected = {}
        patterns.each do |pattern|
          listener.subscribe([pattern])
        rescue ::Redis::CommandError => error
          rejected[pattern] = error
        end
        return rejected if rejected.empty?

        # Unconditional delete: the server rejects by pattern name, so a
        # concurrent re-registration is just as poisoned.
        @lock.synchronize { rejected.each_key { |pattern| @registry.delete(pattern) } }
        rejected.each_value do |error|
          reports ? reports << [error, node_key] : report_error(error, node_key)
        end
        rejected
      end

      # Called from node listener threads on every background error. Connection
      # loss warrants topology reconciliation. A CommandError (on a node thread
      # that is a rejected reconnect replay — user handlers run on the
      # dispatcher, never here) warrants REGISTRY reconciliation: the node
      # evicted the pattern locally, and without a refresh the canonical
      # registry would keep reporting it with no signal left to converge on.
      # Parse errors trigger nothing — the listener stays healthy.
      def handle_node_error(node_key, error)
        report_error(error, node_key)
        request_refresh(node_key) if connection_failure?(error) || error.is_a?(::Redis::CommandError)
      end

      # Called from a node listener's own thread after its replay, and from
      # refresh (post-lock) when a newly attached listener converged. Muted once
      # close began: no user code after close returned.
      def handle_node_reconnect(node_key)
        handler = @lock.synchronize { @closed ? nil : @reconnect_handler }
        handler&.call(node_key)
      rescue StandardError => error
        report_error(error, node_key)
      end

      def connection_failure?(error)
        error.is_a?(::Redis::BaseConnectionError) || error.is_a?(::RedisClient::ConnectionError)
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
            # Buffered items surviving a close are dropped: callers may have torn
            # down handler dependencies the moment close returned.
            dispatch(notification) unless closed?
          end
        end
        thread.name = "redis-cluster-keyspace-notifications"
        thread
      end

      # Reactive refreshes run on their own thread, NOT the dispatcher: during a
      # refresh the dispatcher must keep draining the queue so blocked node
      # readers can process the acks the refresh waits for. The thread also owns
      # failure retries (exponential backoff) — the original signal was already
      # consumed, and a partially-rebuilt node may emit no new one.
      def spawn_refresher
        thread = Thread.new do
          retry_delay = nil
          loop do
            @lock.synchronize do
              @refresh_cond.wait_until { @refresh_needed || @closed }
              break if @closed

              @refresh_needed = false
            end
            break if closed?

            begin
              refresh
              retry_delay = nil
            rescue StandardError => error
              report_error(error, nil)
              retry_delay = [(retry_delay || 0.25) * 2, 30.0].min
              @lock.synchronize do
                @refresh_needed = true
                # Doubles as an interruptible backoff: a request_refresh or
                # close broadcast cuts it short.
                @refresh_cond.wait(retry_delay) unless @closed
              end
            end
          end
        end
        thread.name = "redis-cluster-keyspace-notifications-refresher"
        thread
      end

      # The handler is resolved from the live registry at dispatch time, so
      # buffered events honor unsubscribes and handler replacements, and events
      # for unregistered patterns are dropped rather than leaked.
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
        handler = @lock.synchronize { @error_handler }
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
