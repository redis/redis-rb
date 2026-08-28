# frozen_string_literal: true

class Redis
  module KeyspaceNotifications
    # Owns a dedicated connection and a background listener thread, and dispatches
    # parsed {Notification} objects to per-pattern handlers.
    #
    # Every subscription is a +psubscribe+ pattern (a pattern without glob characters
    # matches itself literally): the listener loop stays terminable, handler routing
    # is an exact lookup on the matched pattern, and database wildcards work. When
    # several subscribed patterns match one message, each handler fires once.
    #
    # Handlers run on the listener thread: they should be fast and must not call
    # blocking Redis commands on the manager's own connection. Handler exceptions
    # and parse errors are reported to the error handler and never kill the listener.
    #
    # On connection loss the manager reconnects (per +reconnect_attempts+, an
    # exponential 0.5s → 30s ladder by default) and re-subscribes every registered
    # pattern. A pattern the server rejects on that replay (e.g. permissions revoked
    # since it was subscribed) is evicted and reported instead of failing every
    # reconnect. Notifications published while the connection was down are lost
    # (pub/sub is fire-and-forget) — use {#on_reconnect} to reconcile after a gap.
    class Manager
      DEFAULT_CLOSE_TIMEOUT = 2
      # A fresh object per (re-)subscription, so concurrent operations can tell "the
      # registration I captured" from "the same pattern re-registered meanwhile".
      # +failed+ marks it dead for good (its subscribe rolled back, or an unsubscribe
      # targeting it completed) so a rollback never resurrects it; a timed-out
      # unsubscribe does NOT mark — that registration legitimately lives on.
      Registration = Struct.new(:handler, :failed)
      private_constant :Registration
      # Sleep per consecutive reconnect attempt; exhausted = give up. The budget
      # resets after every healthy session.
      DEFAULT_RECONNECT_ATTEMPTS = [0.5, 1, 2, 4, 8, 16, 30, 30, 30, 30].freeze
      SUBSCRIBE_ACK_TIMEOUT = 5

      # @param redis [Redis] a dedicated client the manager takes ownership of
      #   (it is closed by {#close}; it must not be used for anything else)
      # @param error_handler [#call, nil] receives every background error; defaults
      #   to warning on $stderr
      # @param reconnect_attempts [Integer, Array<Integer, Float>] number of attempts
      #   trying to reconnect (with no sleep in between), or a list of sleep durations
      #   between attempts — the same semantics as the `reconnect_attempts` option of
      #   {Redis#initialize}. The budget resets after every successful
      #   (re)subscription; an empty list disables reconnection entirely
      def initialize(redis:, error_handler: nil, reconnect_attempts: DEFAULT_RECONNECT_ATTEMPTS)
        @redis = redis
        @error_handler = error_handler
        # Validated here so a bad value fails at the call site instead of killing
        # the listener thread (outside its rescue) after the first connection loss.
        @reconnect_attempts = case reconnect_attempts
        when Integer
          Array.new(reconnect_attempts, 0).freeze
        when Array
          # NaN/Infinity/Complex satisfy Numeric but blow up the backoff
          # arithmetic; real? first — Complex has no #>=.
          unless reconnect_attempts.all? { |delay| delay.is_a?(Numeric) && delay.real? && delay.finite? && delay >= 0 }
            raise ArgumentError, "reconnect_attempts must contain only finite, non-negative sleep durations"
          end

          reconnect_attempts.dup.freeze
        else
          raise ArgumentError,
                "reconnect_attempts must be an Integer or an Array of sleep durations, " \
                "got #{reconnect_attempts.class}"
        end
        @handlers = {} # pattern (BINARY String) => handler (Proc, nil for default)
        # pattern => confirmation GENERATION (monotonic) acked on the current
        # session. Presence answers "is it subscribed?"; a re-subscribing wait
        # compares the generation against its install-time snapshot so only an
        # ack that arrived AFTER the install satisfies it — the entry survives a
        # same-session replacement (the server-side subscription persists).
        @confirmed = {}
        @confirm_seq = 0
        # pattern => queue of unconsumed psubscribe acks in wire order; each entry
        # is the issuing blocking batch's seq (nil for writes with no waiter).
        # Acks arrive in command order, so each shifts the OLDEST entry. A
        # non-final ack resolves nothing pattern-wide but retires its own batch
        # from rejection attribution. Dies with its session.
        @pending_acks = {}
        @default_handler = nil
        @reconnect_handler = nil
        @lock = Monitor.new
        @cond = @lock.new_cond
        @thread = nil
        @listener_error = nil
        @listener_error_epoch = 0
        @reconnect_now = false
        @removing = {} # pattern => the Registration an in-flight unsubscribe targets
        # pattern => { entry:, batch:, seq: } for in-handler registrations not yet
        # server-acked; a session rejection evicts only the oldest (culprit) batch.
        # Age is an explicit seq — re-marking keeps the original Hash position, so
        # map order lies about command order. Dies with its session: a stale
        # marker would win the next session's rejection attribution over the
        # replay itself (cross-session poison is the probing replay's job).
        @unvalidated = {}
        # pattern => { entry:, seq: } for a probing session's unacked single-pattern
        # replay commands. Dies with its session; a lost probe just re-probes.
        @probe_inflight = {}
        # Unacked patterns of the session-opening batch, with @opening_seq its
        # position on the @issue_seq axis: represents the opening in rejection
        # attribution, or its rejection would be pinned on a later command. Dies
        # with its session.
        @opening_pending = {}
        @opening_seq = nil
        # True from opening-ack tracking until the first ack arrives. The
        # subscription client becomes visible to writers a beat before the opening
        # write hits the socket; a write in that gap would precede the opening on
        # the wire and invert @pending_acks against reply order, so
        # write_to_session refuses writes while set. Lifted at session end.
        @establishing = false
        # Issue seq of the blocking subscribe a session-killing rejection was
        # attributed to (nil otherwise). A waiter raises a fresh CommandError only
        # when it names ITS command — raising to every waiter sharing the session
        # rolled back valid registrations (and misled the cluster manager's probes).
        @rejected_wait = nil
        # Set when a rejection was unattributable (the batch replay itself was
        # rejected): the next session replays one pattern per command so the
        # rejection lands on exactly the poisoned pattern.
        @probe_replay = false
        # Set when the listener died with registrations still on the books: the
        # next start is a restart after a lossy gap and must run as a reconnect
        # so {#on_reconnect} announces it.
        @resume_reconnecting = false
        # Wire-orders every issued subscribe batch (assigned under @lock at write
        # time); rejection attribution spans blocking, in-handler, probe and
        # opening commands on this one axis.
        @issue_seq = 0
        # issue seq => the blocking subscribe's patterns still awaiting their own
        # acks. An entry lives until its wait exits or every one of its command's
        # acks was consumed (per-command tokens, not pattern-wide confirmation —
        # an acked batch must retire from rejection attribution immediately).
        @inflight_waits = {}
        # Bumped per session-opening command; waits re-issue an unconfirmed
        # pattern at most ONCE per session (duplicates stack pending acks the
        # final-ack gate must drain).
        @session_seq = 0
        @closing = false
        @closed = false
      end

      # Subscribe to notification channel patterns (build them with {Channels}).
      # Re-subscribing a known pattern replaces its handler. Blocks until the server
      # confirms every pattern, so no notification is missed after it returns. When
      # it raises instead, no trace is left: the registration is rolled back and any
      # pattern the server did confirm in the meantime is reverted.
      # When called from inside a handler it cannot wait for the confirmation (only
      # the listener thread itself reads acknowledgments) and returns immediately
      # after issuing the command instead.
      #
      # @param patterns [Array<String>] channel names or psubscribe patterns
      # @param handler [#call, nil] receives each {Notification}; falls back to the
      #   {#on_notification} default handler when nil
      # @return [void]
      # @raise [SubscriptionError] when the manager is closed or confirmation times out
      def subscribe(*patterns, handler: nil, &block)
        raise ArgumentError, "no patterns given" if patterns.empty?

        handler ||= block
        patterns = patterns.map { |pattern| pattern.to_s.b }
        previous = {}
        installed = {}
        stale_confirmations = {}
        issue_seq = nil
        error_epoch = nil
        @lock.synchronize do
          raise SubscriptionError, "keyspace notifications manager is closed" if @closed || @closing

          patterns.each do |pattern|
            # Snapshot the previous registration for rollback. The handler must be
            # registered before the command is issued: matching messages can
            # arrive ahead of our ack processing.
            unless previous.key?(pattern)
              previous[pattern] = @handlers.key?(pattern) ? { entry: @handlers[pattern] } : nil
            end
            @handlers[pattern] = installed[pattern] = Registration.new(handler)
            # A (re-)subscribe demands a FRESH acknowledgment: the wait accepts
            # only a generation newer than this snapshot, so a replaced
            # registration's confirmation can't report success for a command the
            # server may still reject. The entry itself is kept — the server-side
            # subscription persists across a same-session replacement.
            stale_confirmations[pattern] = @confirmed[pattern]
          end
          # Sequenced in the same hold as the write, so batch age reflects true
          # wire order.
          issue_seq = (@issue_seq += 1)
          # The error-freshness epoch is sampled in this same hold too: sampled at
          # wait entry instead, the listener could process our own rejection in
          # the gap and the waiter would read it as stale (converging via seconds
          # of replay bounces instead of raising promptly).
          error_epoch = @listener_error_epoch
          @inflight_waits[issue_seq] = patterns.uniq unless listener_thread?
          if listening?
            if write_to_session(:psubscribe, patterns)
              track_pending_acks(patterns, issue_seq)
            else
              # Session down (possibly parked in a long backoff): reconnect NOW so
              # the replay covers this pattern within the wait.
              @reconnect_now = true
              @cond.broadcast
            end
          else
            # A dead listener still has every prior registration: restart with the
            # COMPLETE registry (as a reconnect — see start_listener), or earlier
            # subscriptions would silently stop receiving.
            start_listener(@handlers.keys)
          end
        end

        # In-handler call: this is the listener thread, the only one that can read
        # acks, so waiting would stall delivery. Nobody can roll back a rejection
        # either — mark the registrations unvalidated so a session-killing
        # rejection evicts them instead of poisoning every replay.
        if listener_thread?
          @lock.synchronize do
            seq = issue_seq
            patterns.each do |pattern|
              # Mark only the still-live registration (a stale marker matches no
              # future ack). `installed` doubles as the batch token: a rejection
              # is attributable to the OLDEST outstanding batch.
              if @handlers[pattern].equal?(installed[pattern])
                @unvalidated[pattern] = { entry: installed[pattern], batch: installed, seq: seq }
              end
            end
          end
          return
        end

        begin
          wait_for_confirmation(patterns, installed, issue_seq, stale_confirmations, error_epoch)
        rescue StandardError
          rollback_registration(previous, installed)
          raise
        ensure
          # Resolved either way; attribution must stop considering this batch.
          @lock.synchronize { @inflight_waits.delete(issue_seq) }
        end
      end

      # Unsubscribe patterns; with no arguments, everything. Blocks until the server
      # acknowledges, and only then removes the local registration — when it raises,
      # local state still matches the server (the patterns remain subscribed) and the
      # call can simply be retried. In-flight notifications received before the
      # server's acknowledgment are still dispatched to their handler.
      # When called from inside a handler (the one-shot subscription pattern) it
      # cannot wait for the confirmation (only the listener thread itself reads
      # acknowledgments) and commits the removal immediately after issuing the
      # command; no further notifications reach the handler either way.
      # Unsubscribing the last pattern stops the listener thread — a later
      # {#subscribe} restarts it.
      #
      # @param patterns [Array<String>]
      # @return [void]
      # @raise [SubscriptionError] when the server's acknowledgment times out
      def unsubscribe(*patterns)
        patterns = patterns.map { |pattern| pattern.to_s.b }
        targets = nil
        owned = {}
        @lock.synchronize do
          targets = patterns.empty? ? @handlers.keys : patterns.select { |pattern| @handlers.key?(pattern) }
          return if targets.empty?

          # Capture the exact registrations being removed: a concurrent
          # replacement must neither be deleted nor fought. The @removing marks
          # tell the punsubscribe-ack invariant which registration each ack
          # targets, so it can re-establish a replacement our command killed.
          targets.each do |pattern|
            owned[pattern] = @handlers[pattern]
            @removing[pattern] = owned[pattern]
          end

          if listening?
            # Always the captured targets, never a blanket PUNSUBSCRIBE (which
            # would also drop patterns added after our capture). A false return
            # means the session is down — removal is already consistent.
            write_to_session(:punsubscribe, targets)
          end
        end

        begin
          if listener_thread?
            # In-handler call (one-shot pattern): can't wait for the ack — commit
            # the removal now. In-flight messages are dropped by dispatch's
            # registry check; a replay race is reverted at ack time.
            @lock.synchronize do
              targets.each do |pattern|
                # Dead for good: a failed subscribe's rollback must never
                # resurrect this registration.
                owned[pattern].failed = true
                next unless @handlers[pattern].equal?(owned[pattern])

                @handlers.delete(pattern)
                # Purge the pre-ack validation marker too, or it leaks forever.
                @unvalidated.delete(pattern) if @unvalidated[pattern]&.fetch(:entry).equal?(owned[pattern])
              end
            end
            return
          end

          wait_for_removal(targets, owned)
          @lock.synchronize do
            targets.each do |pattern|
              # Dead for good: a failed subscribe's rollback must never
              # resurrect this registration.
              owned[pattern].failed = true
              next unless @handlers[pattern].equal?(owned[pattern])

              @handlers.delete(pattern)
              # Purge the pre-ack validation marker too, or it leaks forever.
              @unvalidated.delete(pattern) if @unvalidated[pattern]&.fetch(:entry).equal?(owned[pattern])
            end
            # A reconnect replay may have re-subscribed a target meanwhile; sweep
            # anything still acknowledged that no registration owns.
            sweep = targets.select { |pattern| @confirmed.key?(pattern) && !@handlers.key?(pattern) }
            punsubscribe_quietly(sweep)
            # The listener may have exited on this removal's ack while a
            # replacement landed after its recheck — revive it for the survivors.
            restart_dead_listener
          end
        ensure
          # Late acks are then judged purely by the live registry: a
          # still-registered pattern is re-established instead of matching a
          # stale mark.
          @lock.synchronize do
            targets.each { |pattern| @removing.delete(pattern) if @removing[pattern].equal?(owned[pattern]) }
          end
        end
        nil
      end

      # @!group Typed subscriptions

      # Watch every event happening to keys matching +key+.
      # @param key [String] key name or glob pattern
      # @param db [Integer, String] database index or "*"
      def subscribe_keyspace(key = "*", db: 0, &handler)
        subscribe(Channels.keyspace(key, db: db), handler: handler)
      end

      # Watch every key receiving events matching +event+.
      # @param event [String] event name (e.g. "expired") or glob pattern
      # @param db [Integer, String] database index or "*"
      def subscribe_keyevent(event = "*", db: 0, &handler)
        subscribe(Channels.keyevent(event, db: db), handler: handler)
      end

      # Watch subkey-level events on keys matching +key+ (Redis 8.8+, flag `S`).
      # @param key [String] key name or glob pattern
      # @param db [Integer, String] database index or "*"
      def subscribe_subkeyspace(key = "*", db: 0, &handler)
        subscribe(Channels.subkeyspace(key, db: db), handler: handler)
      end

      # Watch subkey-level events matching +event+ (Redis 8.8+, flag `T`).
      # @param event [String] event name (e.g. "hdel") or glob pattern
      # @param db [Integer, String] database index or "*"
      def subscribe_subkeyevent(event = "*", db: 0, &handler)
        subscribe(Channels.subkeyevent(event, db: db), handler: handler)
      end

      # Watch events on one exact key + subkey pair (Redis 8.8+, flag `I`).
      # The key is treated literally — glob metacharacters in it are escaped, since
      # every manager subscription is a psubscribe pattern — while the subkey keeps
      # its documented glob behavior.
      # @param key [String] key name (must not contain "\n")
      # @param subkey [String] subkey (e.g. hash field) or glob pattern
      # @param db [Integer, String] database index or "*"
      def subscribe_subkeyspaceitem(key, subkey = "*", db: 0, &handler)
        subscribe(Channels.subkeyspaceitem(Channels.glob_escape(key), subkey, db: db), handler: handler)
      end

      # Watch subkeys affected by +event+ on keys matching +key+ (Redis 8.8+, flag `V`).
      # @param event [String] event name or glob pattern
      # @param key [String] key name or glob pattern
      # @param db [Integer, String] database index or "*"
      def subscribe_subkeyspaceevent(event = "*", key = "*", db: 0, &handler)
        subscribe(Channels.subkeyspaceevent(event, key, db: db), handler: handler)
      end

      # @!endgroup

      # Default handler for notifications whose pattern has no dedicated handler.
      # @yieldparam notification [Notification]
      def on_notification(&block)
        @lock.synchronize { @default_handler = block }
        nil
      end

      # Replaces the error handler. Receives parse errors, handler exceptions and
      # connection errors; must not raise.
      # @yieldparam error [StandardError]
      def on_error(&block)
        # Synchronized for the happens-before edge non-GVL runtimes need.
        @lock.synchronize { @error_handler = block }
        nil
      end

      # Called (on the listener thread) after the manager re-established a lost
      # connection and re-subscribed. Notifications emitted during the gap are lost;
      # use this to reconcile (e.g. invalidate caches).
      def on_reconnect(&block)
        @lock.synchronize { @reconnect_handler = block }
        nil
      end

      # @return [Array<String>] the patterns currently confirmed by the server
      def patterns
        @lock.synchronize { @confirmed.keys }
      end

      # The registered intent, regardless of server confirmation — the set a
      # reconnect replay will re-subscribe. Differs from {#patterns} while the
      # connection is down or acknowledgments are in flight; reconciliation must
      # compare against this.
      #
      # @return [Array<String>] the registered patterns
      def registered_patterns
        @lock.synchronize { @handlers.keys }
      end

      # @return [Boolean] whether the listener is running with at least one confirmed pattern
      def subscribed?
        @lock.synchronize { listening? && !@confirmed.empty? }
      end

      # @return [Boolean]
      def closed?
        # Synchronized for the happens-before edge non-GVL runtimes need
        # (NodeListener#healthy? relies on it).
        @lock.synchronize { @closed }
      end

      # Stop listening, terminate the background thread and close the connection.
      # Idempotent; safe to call from within a handler.
      #
      # @param timeout [Numeric] seconds to wait for the listener thread before
      #   force-closing the connection under it
      # @return [void]
      def close(timeout: DEFAULT_CLOSE_TIMEOUT)
        thread = @lock.synchronize do
          return if @closed

          @closing = true
          # Wake a listener parked in a reconnect backoff — closing the socket
          # can't interrupt a plain sleep.
          @cond.broadcast
          @thread
        end

        begin
          @redis.punsubscribe if thread&.alive? && @redis.subscribed?
        rescue StandardError
          nil # the listener may be mid-teardown; the force-close below covers it
        end

        begin
          # Thread#join re-raises whatever killed the listener; the ensure keeps
          # teardown complete either way (no leaked connection, no half-closed
          # manager).
          if thread && !thread.equal?(Thread.current) && !thread.join(timeout)
            force_close_redis
            thread.join(timeout)
          end
        ensure
          force_close_redis
          # Under @lock (paired with closed?'s read) so the state is visible the
          # moment close returns.
          @lock.synchronize { @closed = true }
        end
        nil
      end
      alias stop close

      private

      def listening?
        @thread&.alive? || false
      end

      def listener_thread?
        Thread.current.equal?(@thread)
      end

      # Waits up to +delay+ seconds between reconnect attempts, waking immediately
      # on close or when a subscribe requests an immediate reconnect. Returns false
      # when the manager is closing.
      def interruptible_backoff(delay)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + delay
        @lock.synchronize do
          until @closing
            if @reconnect_now
              @reconnect_now = false
              return true
            end

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return true if remaining <= 0

            @cond.wait(remaining)
          end
        end
        false
      end

      # Revives a listener that exited while registrations remain (an unsubscribe
      # race: its clean-exit recheck saw only removal targets, but a timeout or a
      # concurrent replacement left a live registration behind). Runs as a
      # reconnect — the survivors' server-side subscriptions died with the
      # session. Called under @lock.
      def restart_dead_listener
        return if listening? || @handlers.empty? || @closing || @closed

        @resume_reconnecting = true
        start_listener(@handlers.keys)
      end

      # Called under @lock (all call sites hold it).
      def start_listener(patterns)
        @listener_error = nil
        # A restart after a lossy death runs as a reconnect so on_reconnect
        # announces the gap's end; a first start has no gap and stays silent.
        reconnecting = @resume_reconnecting
        @resume_reconnecting = false
        @thread = Thread.new { run_listener(patterns, reconnecting: reconnecting) }
        @thread.name = "redis-keyspace-notifications"
      end

      def run_listener(patterns, reconnecting: false)
        attempts = 0

        loop do
          @session_confirmed = false
          begin
            listen(patterns, reconnecting)
            # Clean termination (everything unsubscribed, or close) — except a
            # registration that replaced or arrived alongside the final
            # unsubscribe: the loop exited on the punsubscribe ack without ever
            # reading the replacement's ack, so it must be replayed on a fresh
            # session. Compare REGISTRATIONS, not patterns: the unsubscriber's
            # own target legitimately lingers until this very ack wakes it and
            # must be skipped, while a replacement under the same pattern is a
            # different registration.
            patterns = @lock.synchronize do
              @handlers.reject { |pattern, entry| entry.equal?(@removing[pattern]) }.keys
            end
            break if patterns.empty? || @closing

            reconnecting = false
            attempts = 0
            next
          rescue StandardError => error
            break if @closing

            # The subscription loop bypasses Redis::Client's rescue wrappers.
            error = translate_error(error)
            # Attribution and error publication share ONE lock hold: observed
            # separately, a waiter could see its registration evicted without
            # ever seeing the rejection that names it.
            @lock.synchronize do
              if error.is_a?(CommandError)
                # The server rejected a command on this session. Replies arrive
                # in command order, so the rejected command is the OLDEST
                # outstanding one — attribute it to whichever candidate is
                # oldest on the @issue_seq axis and evict only that; later
                # batches may be valid and get replayed.
                @rejected_wait = nil
                # min_by seq, NOT map order: a re-marked pattern keeps its
                # original Hash position.
                oldest_marker = @unvalidated.values.min_by { |record| record[:seq] }
                # A wait is a candidate only through tokens of its OWN commands
                # still outstanding on THIS session (direct write or re-issue) —
                # a wait whose command died with an older session must not
                # absorb this session's rejection. The opening command's credit
                # token (queue head while the opening ack is outstanding) is the
                # OPENING's command, not the wait's, and is excluded.
                live_wait_tokens = @pending_acks.flat_map do |pattern, tokens|
                  @opening_pending[pattern] ? tokens.drop(1) : tokens
                end
                oldest_wait = live_wait_tokens.select { |token| token && @inflight_waits.key?(token) }.min
                oldest_probe = @probe_inflight.min_by { |_, record| record[:seq] }
                candidates = {}
                candidates[:marker] = oldest_marker[:seq] if oldest_marker
                candidates[:wait] = oldest_wait if oldest_wait
                candidates[:probe] = oldest_probe[1][:seq] if oldest_probe
                # The unacknowledged opening replay competes too — it is the
                # oldest command on this session and must win over commands
                # issued after it.
                candidates[:opening] = @opening_seq unless @opening_pending.empty?
                case candidates.min_by { |_, seq| seq }&.first
                when :marker
                  oldest_batch = oldest_marker[:batch]
                  @unvalidated.each do |pattern, record|
                    next unless record[:batch].equal?(oldest_batch)

                    # Dead for good even if already replaced: a concurrent
                    # rollback must not restore the rejected entry as "the
                    # previous registration".
                    record[:entry].failed = true
                    @handlers.delete(pattern) if @handlers[pattern].equal?(record[:entry])
                  end
                  @unvalidated.delete_if { |_, record| record[:batch].equal?(oldest_batch) }
                when :probe
                  # A probe carries exactly one pattern: the culprit. Evict it;
                  # the un-probed remainder may hide more poison, so probe again.
                  pattern, record = oldest_probe
                  record[:entry].failed = true
                  @handlers.delete(pattern) if @handlers[pattern].equal?(record[:entry])
                  # A wait awaiting the evicted pattern must raise the rejection
                  # instead of resolving the eviction's delete as a replacement.
                  @rejected_wait = @inflight_waits.find { |_, awaiting| awaiting.include?(pattern) }&.first
                  @probe_replay = true
                when :opening
                  # The batch replay names no culprit: probe next session.
                  @probe_replay = true
                when :wait
                  # Name the blocking subscribe: its waiter (and only its)
                  # observes the error and rolls back.
                  @rejected_wait = oldest_wait
                else
                  # Nothing outstanding is attributable — the replay itself was
                  # rejected (e.g. permissions revoked on a long-registered
                  # pattern). Probe next session so the rejection lands on
                  # exactly the poisoned pattern.
                  @probe_replay = true
                end
              end
              @listener_error = error
              # Waits compare against this epoch to tell a FRESH error from a
              # stale one left over from before they started.
              @listener_error_epoch += 1
              # The session's server-side subscriptions died with it: clear
              # confirmations BEFORE the error reaches user code, and everything
              # else whose commands died with the session (a stale @unvalidated
              # marker would misdirect the next session's rejection attribution).
              @confirmed.clear
              @pending_acks.clear
              @probe_inflight.clear
              @opening_pending.clear
              @unvalidated.clear
              # A session that died before its first ack must lift the opening
              # gate, or every future write would be refused forever.
              @establishing = false
              @cond.broadcast
            end
            report_error(error)
          ensure
            # Clean exits pass through here too; after an error exit this is a no-op.
            @lock.synchronize do
              @confirmed.clear
              @pending_acks.clear
              @probe_inflight.clear
              @opening_pending.clear
              @unvalidated.clear
              @establishing = false
              @cond.broadcast
            end
          end

          attempts = 0 if @session_confirmed # the previous session was healthy; fresh budget
          delay = @reconnect_attempts[attempts]
          attempts += 1
          if delay.nil? # the reconnect schedule is exhausted
            # Registrations outlive this death; a later subscribe restarts the
            # listener, and that restart must run as a reconnect.
            @lock.synchronize { @resume_reconnecting = true unless @handlers.empty? }
            break
          end
          break unless interruptible_backoff(delay) # close woke us mid-delay

          patterns = @lock.synchronize { @handlers.keys }
          break if patterns.empty? || @closing

          reconnecting = true
        end
      ensure
        @lock.synchronize do
          @confirmed.clear
          @pending_acks.clear
          @probe_inflight.clear
          @opening_pending.clear
          @unvalidated.clear
          @establishing = false
          @cond.broadcast
        end
      end

      def listen(patterns, reconnected)
        # on_reconnect is documented to fire AFTER the manager re-subscribed:
        # once every replayed pattern is confirmed or no longer registered.
        announce_pending = reconnected ? patterns.dup : nil
        # A probing session replays one pattern per command (opening carries the
        # first; the rest go out on the first ack), so a rejection attributes to
        # exactly one pattern.
        probing = @lock.synchronize do
          probe = @probe_replay
          @probe_replay = false
          probe
        end
        opening = probing ? patterns.first(1) : patterns
        probe_queue = probing ? patterns.drop(1) : nil
        # Track the opening acks before the connect (a failed connect discards
        # them via the session-end clear). @session_seq is bumped alongside so a
        # wait that sampled the old session can retry against this one.
        @lock.synchronize do
          @session_seq += 1
          # No command may reach the new session's socket before the opening
          # command: a write slipping into the establishment gap would invert
          # @pending_acks against reply order. write_to_session refuses writes
          # until the first ack proves the opening went out.
          @establishing = true
          probing ? mark_probes(opening) : track_opening_acks(opening)
        end
        @redis.psubscribe(*opening) do |on|
          on.psubscribe do |pattern, _count|
            key = pattern.b
            registered = false
            pending = false
            announce = false
            @lock.synchronize do
              @session_confirmed = true
              # This ack proves the opening command is on the wire: writes may flow.
              @establishing = false
              # The listener demonstrably recovered: a stale error must not be
              # re-raised by a later wait.
              @listener_error = nil
              # Consume the OLDEST expected ack — replies arrive in command
              # order, so the shifted token names exactly the command this ack
              # answers. The batch is credited on EVERY ack, gated or not: a
              # fully-acked batch can no longer be the rejected command and must
              # retire from attribution immediately.
              tokens = @pending_acks[key]
              token = tokens&.shift
              @pending_acks.delete(key) if tokens && tokens.empty?
              # A pattern's FIRST ack this session is the opening's.
              @opening_pending.delete(key)
              if token && (awaiting = @inflight_waits[token])
                awaiting.delete(key)
                @inflight_waits.delete(token) if awaiting.empty?
              end
              # In-handler markers and probes retire the same way — on THEIR OWN
              # command's ack.
              marker = @unvalidated[key]
              @unvalidated.delete(key) if marker && token && marker[:seq] == token
              probe = @probe_inflight[key]
              @probe_inflight.delete(key) if probe && token && probe[:seq] == token
              # A non-final ack answers an EARLIER command than the pattern's
              # newest one and resolves nothing pattern-wide: confirming here
              # would report success for a command the server may still reject.
              pending = tokens ? !tokens.empty? : false
              next if pending

              # Any final ack retires the validation marker (a non-matching one
              # is stale and would otherwise leak).
              @unvalidated.delete(key)
              if @handlers.key?(key)
                # Fresh generation per final ack: only an ack consumed AFTER a
                # caller's install satisfies its wait.
                @confirmed[key] = (@confirm_seq += 1)
                @cond.broadcast
                registered = true
              end
              if announce_pending
                announce_pending.reject! { |p| @confirmed.key?(p) || !@handlers.key?(p) }
                if announce_pending.empty?
                  announce_pending = nil
                  announce = true
                end
              end
            end
            # A probing session's deferred patterns go out on the first ack.
            if probe_queue
              deferred = probe_queue
              probe_queue = nil
              issue_probes(deferred)
            end
            # The server confirmed a pattern nobody is registered for anymore
            # (an unsubscribe or rollback raced this ack): revert it. A pending
            # ack resolved nothing above and is not reverted either.
            revert_subscription(pattern) unless registered || pending
            fire_reconnect if announce
          end
          on.punsubscribe do |pattern, _count|
            key = pattern.b
            @lock.synchronize do
              @confirmed.delete(key)
              @cond.broadcast
              entry = @handlers[key]
              # Wanted again unless this ack answers the unsubscribe targeting
              # the live registration, or close's blanket punsubscribe
              # (re-establishing would fight the teardown).
              still_wanted = !@closing && !entry.nil? && !entry.equal?(@removing[key])
              # A registered pattern lost its subscription to an unsubscribe
              # aimed at an older, since-replaced registration: re-establish it.
              # Inside the lock hold so the write and its ack tracking stay in
              # wire order against concurrent subscribes.
              psubscribe_quietly([pattern]) if still_wanted
            end
          end
          on.pmessage do |pattern, channel, payload|
            dispatch(pattern, channel, payload)
          end
        end
      end

      def dispatch(pattern, channel, payload)
        notification = Parser.parse(channel, payload, pattern: pattern)
        if notification.nil?
          error = ParseError.new(
            "received a non-notification message on #{channel.inspect}",
            channel: channel, payload: payload
          )
          report_error(error)
          return
        end

        key = pattern.b
        handler = @lock.synchronize do
          # Messages for a pattern being unsubscribed are dropped rather than
          # leaked to the default handler.
          entry = @handlers[key]
          entry ? (entry.handler || @default_handler) : nil
        end
        handler&.call(notification)
      rescue StandardError => error
        report_error(error)
      end

      # Waits for every pattern that is still THIS call's to confirm. A pattern
      # removed or replaced by a concurrent operation stops being waited for — it
      # resolves to that operation's outcome (timing out on it would tear down
      # the batch's innocent siblings).
      def wait_for_confirmation(patterns, installed, issue_seq, stale_confirmations, entry_epoch)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBSCRIBE_ACK_TIMEOUT
        restarted = false
        reissued_session = nil
        @lock.synchronize do
          # entry_epoch was sampled in the same hold that issued the command, so
          # a rejection processed before this wait entered still reads as fresh.
          loop do
            # A fresh CommandError is raised promptly — but ONLY when attribution
            # named THIS wait's command; a rejection pinned elsewhere must not
            # tear down an innocent waiter (its command is replayed and confirms).
            # The epoch is consumed either way so the same error is not
            # re-examined every wake. Checked BEFORE the resolution break: a
            # probe eviction deletes this call's registration in the same stroke
            # as it names this wait, and the raise must win over "resolved by
            # replacement".
            if (rejection = @listener_error).is_a?(CommandError) && @listener_error_epoch > entry_epoch
              raise rejection if @rejected_wait == issue_seq

              entry_epoch = @listener_error_epoch
            end

            break if patterns.all? { |pattern| confirmed_or_replaced?(pattern, installed, stale_confirmations) }

            unless listening?
              raise @listener_error if @listener_error && @listener_error_epoch > entry_epoch
              if @closing || @closed || restarted || @handlers.empty?
                raise SubscriptionError, "keyspace notifications listener died before confirming"
              end

              # The previous listener ended naturally (e.g. a racing
              # unsubscribe-all); restart it once.
              start_listener(@handlers.keys)
              restarted = true
            end

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise SubscriptionError, "timed out waiting for subscription confirmation" if remaining <= 0

            @cond.wait([remaining, 0.05].min)
            # At most ONE re-issue per listener session: it exists to cover the
            # session-establishment window, and duplicates stack pending acks the
            # final-ack gate must drain. Marked only when the write went out.
            if @session_seq != reissued_session &&
               reissue_unconfirmed(patterns, installed, issue_seq, stale_confirmations)
              reissued_session = @session_seq
            end
          end
        end
        nil
      end

      # Re-issues psubscribe for patterns the server hasn't acked yet (covers a
      # pattern registered while the session wasn't established). Re-subscribing
      # is harmless — the server re-acks. Carries the batch's seq: when the
      # original write died with its session, the re-issue IS the batch's command.
      def reissue_unconfirmed(patterns, installed, issue_seq, stale_confirmations)
        unconfirmed = patterns.select do |pattern|
          @handlers[pattern].equal?(installed[pattern]) && !fresh_confirmation?(pattern, stale_confirmations)
        end
        psubscribe_quietly(unconfirmed, issue_seq)
      end

      # A pattern stops being waited for once its confirmation is newer than the
      # caller's install-time snapshot, or once its registration was replaced or
      # removed (it then resolves to that operation's outcome). Called under @lock.
      def confirmed_or_replaced?(pattern, installed, stale_confirmations)
        fresh_confirmation?(pattern, stale_confirmations) || !@handlers[pattern].equal?(installed[pattern])
      end

      # Whether the pattern's confirmation was minted AFTER the caller's install:
      # a kept-but-stale entry reports the pattern as subscribed to the world but
      # must not satisfy the replacing call's wait. Called under @lock.
      def fresh_confirmation?(pattern, stale_confirmations)
        confirmation = @confirmed[pattern]
        !confirmation.nil? && confirmation != stale_confirmations[pattern]
      end

      # Blocks until the server no longer acknowledges any still-owned target as
      # subscribed. A dead or restarting session counts as removed (its
      # confirmations are cleared); a target replaced by a concurrent subscribe
      # stops being waited for — it is that subscribe's to confirm.
      def wait_for_removal(patterns, owned)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBSCRIBE_ACK_TIMEOUT
        reissued_session = nil
        @lock.synchronize do
          until patterns.none? { |pattern| @confirmed.key?(pattern) && @handlers[pattern].equal?(owned[pattern]) }
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              # Clear the marks ATOMICALLY with the timeout decision: after the
              # raise the registration stays (caller retries), and a late ack
              # must see no stale mark.
              patterns.each { |pattern| @removing.delete(pattern) if @removing[pattern].equal?(owned[pattern]) }
              # The listener may have exited believing this removal completes
              # it; the surviving registrations would sit deaf — revive it.
              restart_dead_listener
              raise SubscriptionError, "timed out waiting for unsubscription confirmation"
            end

            @cond.wait([remaining, 0.05].min)
            # At most ONE re-issue per session (it exists to catch a reconnect
            # replay re-subscribing a removal target); every-wake duplicates
            # flap `subscribed?`, which the cluster wrapper prunes nodes on.
            pending = patterns.select do |pattern|
              @confirmed.key?(pattern) && @handlers[pattern].equal?(owned[pattern])
            end
            if @session_seq != reissued_session && punsubscribe_quietly(pending)
              reissued_session = @session_seq
            end
          end
        end
        nil
      end

      # Mirror of reissue_unconfirmed for the removal path. Returns whether the
      # command actually went out on the session.
      def punsubscribe_quietly(patterns)
        return false if patterns.empty? || !@redis.subscribed?

        write_to_session(:punsubscribe, patterns)
      end

      def psubscribe_quietly(patterns, batch_seq = nil)
        return false if patterns.empty? || !@redis.subscribed?

        written = write_to_session(:psubscribe, patterns)
        track_pending_acks(patterns, batch_seq) if written
        written
      end

      # Records one expected ack per pattern for a psubscribe that went out,
      # remembering WHICH command it was (the blocking batch's seq, nil for writes
      # with no waiter). EVERY psubscribe write must pass through here, or its ack
      # would be credited to another command's token.
      def track_pending_acks(patterns, batch_seq = nil)
        @lock.synchronize do
          patterns.each { |pattern| (@pending_acks[pattern.b] ||= []) << batch_seq }
        end
      end

      # Tracks the opening batch's acks, crediting each pattern to the oldest
      # blocking wait awaiting it — the opening IS the session's (re-)issue of
      # that wait's command. Left uncredited, a completed wait would linger in
      # rejection attribution until its caller thread is scheduled.
      def track_opening_acks(patterns)
        @lock.synchronize do
          # Sequenced before any later write on this session can take a seq, so
          # "opening still unacknowledged" outranks everything issued after it.
          @opening_seq = (@issue_seq += 1)
          patterns.each do |pattern|
            @opening_pending[pattern] = true
            token = @inflight_waits.select { |_, awaiting| awaiting.include?(pattern) }.keys.min
            track_pending_acks([pattern], token)
          end
        end
      end

      # Probe bookkeeping for the probing session's opening command.
      def mark_probes(patterns)
        @lock.synchronize do
          patterns.each do |pattern|
            entry = @handlers[pattern]
            next unless entry

            seq = (@issue_seq += 1)
            @probe_inflight[pattern] = { entry: entry, seq: seq }
            track_pending_acks([pattern], seq)
          end
        end
      end

      # Issues one single-pattern psubscribe per remaining pattern of a probing
      # session (listener thread, after the opening ack). Sequenced and written
      # under one lock hold apiece so probe age reflects wire order; a dead
      # session stops the loop with no dangling probe entries.
      def issue_probes(patterns)
        patterns.each do |pattern|
          alive = @lock.synchronize do
            entry = @handlers[pattern]
            next true unless entry

            seq = (@issue_seq += 1)
            if write_to_session(:psubscribe, [pattern])
              @probe_inflight[pattern] = { entry: entry, seq: seq }
              track_pending_acks([pattern], seq)
              true
            else
              false
            end
          end
          break unless alive
        end
      end

      # Block-less writes race the session's teardown; SubscriptionError, a
      # connection error, or redis-client's discarded-connection NoMethodError all
      # mean "session gone" — the replay and ack-time invariants own convergence.
      # Returns false then, true when the write went out.
      def write_to_session(verb, patterns)
        # The opening command must be FIRST on the wire: until its ack arrives,
        # every other write is refused exactly like a down session.
        return false if @establishing

        @redis.public_send(verb, *patterns)
        true
      rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
        false
      rescue NoMethodError => error
        # NoMethodError#receiver raises ArgumentError when the error carries no
        # receiver information — treat that as "not the torn-down shape".
        receiver_nil = begin
          error.receiver.nil?
        rescue ArgumentError
          false
        end
        raise unless error.name == :write && receiver_nil

        false
      end

      # A raised subscribe must leave no trace: restore each pattern's previous
      # registration exactly, and revert any newly-added pattern the server did
      # confirm meanwhile. Later acks are reverted by the listener's registry check.
      def rollback_registration(previous, installed)
        revert = []
        @lock.synchronize do
          previous.each do |pattern, entry|
            # Dead wherever it ends up: a concurrent failed subscribe's rollback
            # must not restore it as "the previous registration".
            installed[pattern].failed = true
            # Re-registered by a concurrent subscribe meanwhile: theirs, not ours.
            next unless @handlers[pattern].equal?(installed[pattern])

            if entry && !entry[:entry].failed
              @handlers[pattern] = entry[:entry]
            else
              @handlers.delete(pattern)
              revert << pattern if @confirmed.key?(pattern)
            end
          end
        end
        return if revert.empty?

        write_to_session(:punsubscribe, revert)
      end

      # Best-effort punsubscribe of a single server-confirmed but unregistered
      # pattern (called from the listener thread's ack handling).
      def revert_subscription(pattern)
        write_to_session(:punsubscribe, [pattern])
      end

      def fire_reconnect
        # Read under @lock, called outside it — user code must never run while
        # the manager lock is held.
        handler = @lock.synchronize { @reconnect_handler }
        handler&.call
      rescue StandardError => error
        report_error(error)
      end

      def report_error(error)
        handler = @lock.synchronize { @error_handler }
        if handler
          handler.call(error)
        else
          warn("Redis keyspace notifications error: #{error.class}: #{error.message}")
        end
      rescue StandardError
        nil # a broken error handler must never kill the listener
      end

      def force_close_redis
        @redis.close
      rescue StandardError
        nil
      end

      def translate_error(error)
        return error unless error.is_a?(RedisClient::Error)

        begin
          Client.translate_error!(error)
        rescue StandardError => translated
          translated
        end
      end
    end
  end
end
