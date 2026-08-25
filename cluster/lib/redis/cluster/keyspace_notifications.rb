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
    # {#refresh}, which re-enumerates the primaries via `CLUSTER NODES` (membership,
    # not slot coverage — a scale-out primary is discovered before it owns a single
    # slot), drops listeners for vanished/demoted nodes and subscribes new primaries
    # to every registered pattern. There is no proactive polling — after intentionally
    # adding primaries (scale-out) call {#refresh} yourself before resharding, because
    # a brand-new node emits no error signal; the listener then attaches ahead of the
    # first migrated key.
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
        # Called from inside a handler, this runs on the dispatcher thread: the
        # ack-blocking fan-out below could deadlock against node readers stuck on a
        # full queue (they can't read acks until the dispatcher drains). Defer the
        # fan-out to the refresher, which reconciles from the updated registry
        # (whose catch-up also identifies and evicts server-rejected patterns).
        return request_refresh(nil) if dispatcher_thread?

        # Fan out WITHOUT holding the lock: each per-node subscribe blocks on that
        # node's acknowledgment (seconds against a sick node) and must not stall
        # dispatch, refresh or close. A refresh racing this call reconciles from the
        # already-updated registry, and re-subscribing is idempotent (re-acked).
        rejected = {}
        failures = {}
        listeners.each do |node_key, listener|
          listener.subscribe(patterns)
        rescue ::Redis::CommandError => error
          # The server REJECTED a pattern (deterministic — e.g. ACL NOPERM), which
          # best-effort handling must not swallow: left registered, the pattern
          # would fail every future catch-up batch on every primary. Identify and
          # evict the culprit(s) once (evict_rejected reports each rejection), then
          # raise below — matching the standalone contract that a rejected
          # subscribe raises and leaves no registration. Every OTHER node's error —
          # the same rejection repeated, or one unattributable to any single
          # pattern (each succeeded individually: transient session trouble) — is
          # collected like any node failure, never silently dropped.
          culprits = {}
          if rejected.empty?
            begin
              culprits = evict_rejected(listener, node_key, patterns)
            rescue StandardError => probe_error
              # The per-pattern probes ride the very session the batch rejection
              # just bounced, so they can fail with session/connection errors of
              # their own. Raised from inside this rescue clause, such an error
              # would NOT be caught by the sibling StandardError rescue below —
              # it would abort the whole fan-out: remaining nodes skipped, no
              # reports, no refresh, and the poison left registered. Treat it as
              # this node's failure instead; the refresher's catch-up re-runs
              # the attribution on a stable session and evicts the poison there.
              failures[node_key] = probe_error
              next
            end
          end
          if culprits.empty?
            failures[node_key] = error
          else
            rejected = culprits
          end
        rescue StandardError => error
          failures[node_key] = error
        end
        # Accumulate-then-report, like #refresh: every failed node is reported
        # individually and healed by the refresher's catch-up. That catch-up also
        # converges nodes that accepted an evicted pattern (before the rejection,
        # or under a diverging per-node ACL): the pattern is no longer registered,
        # so it is unsubscribed as an extra.
        failures.each { |node_key, error| report_error(error, node_key) }
        request_refresh(nil) unless rejected.empty? && failures.empty?
        raise rejected.values.first unless rejected.empty?

        # Reconcile via the refresher when the fan-out could not have done the job:
        # no listeners exist at all (a previously failed refresh left none, and with
        # no connections there is no error signal to trigger recovery), or a
        # concurrent unsubscribe's fan-out may have undone ours after the fact.
        if listeners.empty? || @lock.synchronize { patterns.any? { |pattern| !@registry.key?(pattern) } }
          request_refresh(nil)
        end
        # A close racing this call tore the listeners down after our snapshot and
        # muted the refresher: returning success would leave the caller believing
        # a subscription exists on a closed manager.
        raise SubscriptionError, "keyspace notifications manager is closed" if @closed

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
        # Nothing was registered: fanning out an empty list would mean "everything"
        # at the node level and wipe patterns a concurrent subscribe just installed.
        return if targets.empty?

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
        # Synchronized like every other piece of shared state: an unsynchronized
        # write has no happens-before edge with the background threads' reads, so
        # a non-GVL runtime could keep invoking the replaced handler indefinitely.
        @lock.synchronize { @error_handler = block }
        nil
      end

      # Called with the node_key after a node's subscriptions were (re-)established
      # following a gap — its listener reconnected and replayed on its own, a
      # refresh rebuilt it, or a refresh attached a primary not listened to before
      # (a promoted replica replacing a dead primary under a new address, or a
      # scale-out node whose keys arrived ahead of our subscription). Notifications
      # the node emitted during the gap are lost (pub/sub is fire-and-forget); use
      # this to reconcile, e.g. invalidate caches for that node's keys. The
      # callback may fire more than once for a single gap (a listener's own
      # reconnect can race the refresh that would rebuild it), runs on a
      # background thread, and should be fast and must not raise.
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
        # Called from inside a notification handler, this runs on the dispatcher
        # thread: the ack-blocking catch-ups below could deadlock against node
        # readers stuck on a full queue (their acks flow only while the dispatcher
        # drains). Defer to the refresher thread, like #subscribe and #unsubscribe.
        return request_refresh(nil) if dispatcher_thread?

        # Rejection reports collected under the refresh lock are delivered only
        # after it is released (see the ensure): the error handler is user code
        # that may call #close or #refresh, which acquire this same non-reentrant
        # lock — invoked while held, that raises ThreadError, report_error's guard
        # swallows it, and a requested close would be silently dropped.
        deferred_reports = []
        # Reconnect announcements are deferred for the same reason.
        deferred_reconnects = []
        @refresh_lock.synchronize do
          return if @closed

          # current_primaries raises (keeping the existing listeners) on a view
          # that is not a topology to reconcile against — no slot-owning primary,
          # or concealed/ambiguous endpoints.
          primaries = current_primaries

          failures = {}

          # Prune vanished/demoted/unhealthy listeners under the lock; the
          # ack-blocking catch-ups below run WITHOUT it so dispatch and the API stay
          # responsive (close cannot interleave — it is excluded by @refresh_lock).
          stale = @lock.synchronize do
            expect_subscribed = !@registry.empty?
            gone_keys = @listeners.keys - primaries.keys
            primaries.each_key do |node_key|
              listener = @listeners[node_key]
              gone_keys << node_key if listener && !listener.healthy?(expect_subscribed)
            end
            gone_keys.map { |node_key| @listeners.delete(node_key) }
          end
          stale.compact.each(&:close)

          primaries.each do |node_key, (host, port)|
            # A close racing this refresh raises @closed first, then waits on
            # @refresh_lock: abort at the node boundary instead of making it sit
            # out every remaining ack-blocking catch-up (see #close).
            break if @closed

            listener = @lock.synchronize { @listeners[node_key] }
            created = false
            begin
              unless listener
                created = true
                listener = NodeListener.new(
                  node_key, sidecar_options(host, port), @queue,
                  on_error: method(:handle_node_error), on_reconnect: method(:handle_node_reconnect)
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
                break if @closed

                begin
                  listener.catch_up(snapshot)
                rescue ::Redis::CommandError
                  # A server rejection is deterministic, NOT a node failure: the
                  # connection is healthy, and the generic handling below would
                  # delete every listener (all primaries reject the same pattern)
                  # and loop the refresher forever over the poisoned registry.
                  # Identify and evict the rejected pattern(s); the next pass
                  # converges on the cleaned registry. An unattributable batch
                  # failure re-raises into the per-node failure handling.
                  raise if evict_rejected(listener, node_key, snapshot, reports: deferred_reports).empty?
                end
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
              request_refresh(nil) unless converged || @closed
              # A NEWLY ATTACHED listener converged while patterns are registered:
              # whatever the node emitted before this catch-up is lost — announce
              # the gap's end once the refresh lock is released (user code must
              # never run under it, see deferred_reports). Keying on creation
              # covers every gap shape with one rule: a rebuilt listener (its
              # predecessor was pruned or failed, possibly refreshes ago), a
              # promoted replica replacing a dead primary under a NEW node_key
              # (the gap opened under the old key, but the keys now live here),
              # and a scale-out primary (subscribed only from this catch-up on).
              # With nothing registered there is no gap to speak of.
              deferred_reconnects << node_key if created && converged && !snapshot.empty?
            rescue StandardError => error
              failures[node_key] = error
              # The gap this failure opens (or keeps open) is announced by the
              # refresh that eventually re-creates and converges the node.
              @lock.synchronize { @listeners.delete(node_key) }&.close
            end
          end
          # An aborted (closing) refresh reports nothing: close is tearing the
          # remaining listeners down right behind this lock.
          raise KeyspaceNotificationsRefreshError, failures unless failures.empty? || @closed
        end
        nil
      ensure
        # Checked per item, not once: this runs after the refresh lock is released,
        # so a concurrent close can complete its teardown at any point in the loop
        # — and callers commonly dismantle callback dependencies the moment close
        # returns. Like queue items surviving close, callbacks that haven't started
        # by then are dropped, not delivered. (A callback that already began can
        # still finish after close returns — the same bounded exposure as a
        # mid-flight notification handler outliving close's bounded dispatcher
        # join; full exclusion would need close to block on user code.)
        deferred_reports&.each { |error, node_key| report_error(error, node_key) unless @closed }
        deferred_reconnects&.each { |node_key| handle_node_reconnect(node_key) unless @closed }
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
        # The write in #close happens under @lock; pairing the read gives the
        # happens-before edge non-GVL runtimes need to observe it reliably.
        @lock.synchronize { @closed }
      end

      # Close every node listener, stop the dispatcher and release all connections.
      # Idempotent.
      #
      # @return [void]
      def close
        # @closed is raised BEFORE waiting on @refresh_lock: an in-flight refresh
        # can hold that lock across ack-blocking per-node catch-ups (tens of
        # seconds on a big cluster), and its closed-checks abort it at the next
        # node boundary once the flag is up — the unbounded wait below then ends
        # promptly without ever skipping the teardown.
        @lock.synchronize do
          @closed = true
          @refresh_cond.broadcast # wake the refresher (idle or in backoff) so it exits
        end
        # Still serialized with refresh via @refresh_lock: otherwise a refresh past
        # its closed-checks could recreate subscribed listeners on a manager that
        # close just tore down, leaking their threads and connections.
        @refresh_lock.synchronize do
          listeners = @lock.synchronize { @listeners.values.tap { @listeners.clear } }
          # Queue first: node readers blocked pushing into a full queue are stuck in
          # Ruby, not Redis I/O — closing their connections cannot unblock them, but
          # ClosedQueueError from the closed queue does (their enqueue rescues it).
          @queue.close
          # In parallel: each listener close joins that node's threads (bounded,
          # but up to seconds apiece) and the listeners are independent — serial
          # teardown would make close O(nodes). NodeListener#close never raises.
          listeners.map { |listener| Thread.new { listener.close } }.each(&:join)
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
        # CLUSTER NODES rather than CLUSTER SLOTS: slot-oriented output cannot
        # show a primary that owns no slots yet, so the documented "refresh after
        # adding primaries" would silently skip a scale-out node — and the slots
        # later moved onto it produce no error signal to catch up on, losing its
        # notifications until some unrelated refresh. Membership output lists
        # zero-slot primaries too, letting the listener attach before the first
        # migrated key arrives.
        masters, dropped = @cluster.cluster("nodes").partition do |node|
          flags = node["flags"]
          # "fail?" (suspected, unconfirmed) is kept — its slots are still
          # assigned to it; confirmed-failed, addressless and handshaking nodes
          # cannot be usefully subscribed to and are dropped like a demotion.
          flags.include?("master") && (flags & %w[fail noaddr handshake]).empty?
        end
        # A dropped master still listed as a slot owner is a mid-failover view:
        # its replacement has not claimed the slots yet. Reconciling against it
        # would succeed with N-1 listeners and stop the reactive refresher's
        # retries — the promoted primary would then be silently missed until an
        # unrelated refresh. Raise instead (keeping the current listeners): the
        # refresher's backoff loop retries until the promotion completes.
        if dropped.any? { |node| node["flags"].include?("master") && node["slots"] }
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES reports a failed primary still owning slots " \
                "(failover in progress); keeping existing listeners"
          )
        end
        # A view without a single slot-owning primary (mid-reset, or a degraded
        # node's view) is not a topology to reconcile against: tearing every
        # listener down would leave nothing to emit the connection errors that
        # drive reactive recovery. Keep the current listeners and raise — the
        # refresher's backoff loop (or the caller) retries.
        if masters.none? { |node| node["slots"] }
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES reported no slot-owning primaries; keeping existing listeners"
          )
        end

        # The address field is "ip:port@cport" (a ",hostname" may trail the
        # cport since Redis 7); rpartition keeps a bare IPv6 address's own
        # colons intact.
        addresses = masters.map { |node| node["ip_port"].split("@", 2).first.rpartition(":").values_at(0, 2) }
        # A server configured to conceal node endpoints announces nil/empty
        # addresses, telling clients to reuse their existing connection info — which
        # per-node sidecar connections cannot do. Unless fixed_hostname supplies the
        # dial target, fail loudly (keeping current listeners) instead of silently
        # subscribing to ":<port>".
        if !@base_options[:fixed_hostname] && addresses.any? { |ip, _| ip.nil? || ip.empty? }
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES conceals node endpoints; per-node notification " \
                "sidecars need reachable addresses (or the fixed_hostname option)"
          )
        end

        primaries = addresses.to_h { |ip, port| ["#{ip}:#{port}", [ip, port]] }
        # Distinct primaries collapsing onto one dial target (concealed endpoints
        # sharing a port under fixed_hostname): a single sidecar cannot listen to
        # them all — fail loudly instead of silently dropping the rest.
        if primaries.size < masters.size
          raise KeyspaceNotificationsRefreshError.new(
            {}, "CLUSTER NODES reports #{masters.size} primaries but only " \
                "#{primaries.size} distinguishable endpoints; per-node notification " \
                "sidecars need a unique address per primary"
          )
        end
        primaries
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
        # reconnect_attempts is forced OFF at the transport: each sidecar's core
        # manager owns its reconnection schedule (and refresh rebuilds on top),
        # so a cluster client configured with its own retry ladder must not make
        # every sidecar connect attempt sit that ladder out inside redis-client.
        connection_options_from_nodes.merge(options)
                                     .merge(host: host, port: Integer(port), db: 0, reconnect_attempts: 0)
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
          options_from_node_url(node)
        when Hash
          # The documented hash form accepts the same options as a single-server
          # connection (ssl_params, credentials, a standalone-style :url whose TLS
          # and credentials may exist nowhere else, ...): pass everything through
          # except the seed's addressing — sidecars dial the discovered primaries.
          # :path is seed addressing too: standalone configs prefer a Unix socket
          # over host/port, so keeping it would point every sidecar at the seed.
          # Explicit keys override what the :url says.
          url_options = node[:url] ? options_from_node_url(node[:url]) : {}
          url_options.merge(node.except(:host, :port, :url, :path))
        else
          {}
        end
      rescue URI::InvalidURIError
        {}
      end

      # An exact mirror of redis-cluster-client's parse_node_url (cluster_config.rb):
      # the sidecars must authenticate with byte-identical credentials to the
      # cluster client's own node connections, whatever that parser's quirks —
      # including form-style decoding (`+` becomes a space there too). Diverging
      # toward stricter URI semantics here would make sidecars fail against
      # clusters that connect fine today; such a change belongs upstream, where
      # both sides would inherit it together.
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

      # A CommandError from a batch subscribe means the server rejected one of the
      # patterns. The rejection is deterministic (retrying cannot fix it), so the
      # pattern must not stay registered: every future catch-up batch containing it
      # would fail on every primary. Identify the culprit(s) by subscribing one
      # pattern at a time — the valid ones simply end up subscribed — then evict
      # them from the registry and report each. Returns the rejected patterns
      # mapped to their errors; empty when the failure was not attributable to any
      # single pattern (each succeeded individually).
      # When +reports+ is given (the refresh path, which holds the non-reentrant
      # refresh lock), rejections are collected there instead of reported inline —
      # the error handler must never run under that lock (see #refresh).
      def evict_rejected(listener, node_key, patterns, reports: nil)
        rejected = {}
        patterns.each do |pattern|
          listener.subscribe([pattern])
        rescue ::Redis::CommandError => error
          rejected[pattern] = error
        end
        return rejected if rejected.empty?

        # Unconditional delete: the server rejects by pattern name, so a concurrent
        # re-registration under a different handler is just as poisoned.
        @lock.synchronize { rejected.each_key { |pattern| @registry.delete(pattern) } }
        rejected.each_value do |error|
          reports ? reports << [error, node_key] : report_error(error, node_key)
        end
        rejected
      end

      # Called from node listener threads on every background error of a node.
      # Only connection/session loss warrants topology reconciliation: parse errors
      # and handler failures leave the node listener healthy, and refreshing on them
      # would hammer CLUSTER NODES and re-subscribe every primary for e.g. a stream
      # of malformed publications on a watched channel.
      def handle_node_error(node_key, error)
        report_error(error, node_key)
        request_refresh(node_key) if connection_failure?(error)
      end

      # Called from a node listener's own thread after its core manager replayed a
      # lost connection, and from refresh (after releasing its lock) when a newly
      # attached listener converged. Muted once close began: "node recovered" is
      # meaningless on a closed manager, and a replay completing right as its
      # listener is torn down must not run user code after close returned.
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
