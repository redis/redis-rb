# frozen_string_literal: true

class Redis
  module KeyspaceNotifications
    # Owns a dedicated connection and a background listener thread, and dispatches
    # parsed {Notification} objects to per-pattern handlers.
    #
    # Every subscription is a +psubscribe+ pattern (a pattern without glob characters
    # matches itself literally). This keeps the listener loop terminable, makes handler
    # routing an exact lookup on the matched pattern, and allows database wildcards.
    # When several subscribed patterns match the same message, each pattern's handler
    # fires once (server behavior).
    #
    # Handlers run on the listener thread: they should be fast and must not call
    # blocking Redis commands on the manager's own connection. Exceptions raised by
    # handlers (and message parse errors) are reported to the error handler and never
    # kill the listener.
    #
    # If the connection is lost, the manager reconnects (following the
    # +reconnect_attempts+ schedule, an exponential 0.5s → 30s ladder by default) and
    # re-subscribes every registered pattern. Notifications published while the
    # connection was down are lost forever (pub/sub is fire-and-forget) — register an
    # {#on_reconnect} callback to reconcile after a gap.
    class Manager
      DEFAULT_CLOSE_TIMEOUT = 2
      # Registry values: a fresh object per (re-)subscription, so a concurrent
      # unsubscribe can tell "the registration I captured" apart from "the same
      # pattern re-registered meanwhile" and never removes or fights the latter.
      # +failed+ marks a registration as dead for good — set when its own subscribe
      # rolled back, or when an unsubscribe targeting it completed — so a concurrent
      # failed subscribe's rollback never resurrects it as "the previous
      # registration". (A timed-out unsubscribe does NOT mark: there the
      # registration legitimately lives on and the caller retries.)
      Registration = Struct.new(:handler, :failed)
      private_constant :Registration
      # One sleep duration (in seconds) per consecutive reconnect attempt; the manager
      # gives up when the schedule is exhausted. The budget resets after every healthy
      # session, so only a persistent outage runs through the whole ladder (~2 minutes).
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
        @reconnect_attempts = if reconnect_attempts.is_a?(Integer)
          Array.new(reconnect_attempts, 0).freeze
        else
          reconnect_attempts.dup.freeze
        end
        @handlers = {} # pattern (BINARY String) => handler (Proc, nil for default)
        # pattern (BINARY String) => confirmation GENERATION (monotonic), as acked
        # by the server on the current session. Consumers of "is it subscribed?"
        # test presence; a re-subscribing caller's wait compares the generation
        # against its install-time snapshot instead — only an acknowledgment that
        # arrived AFTER the install satisfies it. That keeps the entry in place
        # across a same-session replacement (the server-side subscription
        # genuinely persists, so `patterns`/`subscribed?` stay truthful and a
        # failed call's rollback leaves no observable dent) while still refusing
        # to report success on the replaced registration's stale confirmation.
        @confirmed = {}
        @confirm_seq = 0
        # pattern (BINARY String) => queue of psubscribe commands issued on the
        # live session whose acknowledgment has not been consumed yet, in wire
        # order — each entry is the issuing blocking batch's seq (nil for writes
        # with no waiting batch). Acks arrive in command order, so each shifts
        # the OLDEST entry: the queue names exactly which command an ack answers.
        # An ack that leaves the queue non-empty resolves nothing pattern-wide —
        # with several commands on the wire (two callers re-subscribing the same
        # pattern concurrently), an earlier command's ack must neither confirm
        # the newer registration (whose own, later command the server may still
        # reject) nor retire its validation marker — but it DOES credit its own
        # batch's retirement from rejection attribution. Cleared together with
        # @confirmed at session end: pending acks die with their session.
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
        # pattern => { entry: Registration, batch: Object, seq: Integer } for
        # registrations installed from a handler and not yet server-acked; batch
        # identifies the subscribe call and seq its issue order, so a session
        # rejection drops only the oldest (culprit) batch. Age must be an explicit
        # sequence: re-marking a pattern keeps its ORIGINAL Hash position, so map
        # order lies about command order when a later call replaces an earlier
        # call's pattern.
        @unvalidated = {}
        # Numbers every issued subscribe batch — in-handler AND blocking — in wire
        # order (assigned under @lock at write time). Rejection attribution must
        # span both kinds: a blocking command has its own waiter to roll it back,
        # but only this sequence tells the listener that the rejected command was
        # the blocking one and not the oldest in-handler batch.
        @issue_seq = 0
        # issue seq => the blocking subscribe's patterns still awaiting their own
        # acknowledgments; the entry lives until its wait exits or every one of
        # its command's acks was consumed off the reply stream (tracked per
        # issued command via the @pending_acks tokens, NOT via pattern-wide
        # confirmation: an overlapping younger command's unread ack gates the
        # pattern's confirmation, and that must not keep an already-acknowledged
        # batch in rejection attribution as a possible culprit, shielding the
        # genuinely-poisoned younger batch).
        @inflight_waits = {}
        # Bumped when a listener session starts issuing its opening command. Waits
        # re-issue an unconfirmed pattern at most ONCE per session: every duplicate
        # adds a pending acknowledgment the final-ack gate must drain, so a
        # time-based retry (the pre-fix every-50ms loop) under a delayed listener
        # would keep pushing confirmation behind fresh duplicates of itself.
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
        @lock.synchronize do
          raise SubscriptionError, "keyspace notifications manager is closed" if @closed || @closing

          patterns.each do |pattern|
            # Remember what registration looked like before, so a failed subscribe
            # can restore it exactly. The handler must be registered before the
            # command is issued: matching messages can arrive ahead of our ack
            # processing and dispatch needs to find it.
            unless previous.key?(pattern)
              previous[pattern] = @handlers.key?(pattern) ? { entry: @handlers[pattern] } : nil
            end
            @handlers[pattern] = installed[pattern] = Registration.new(handler)
            # A (re-)subscribe demands a FRESH acknowledgment: a confirmation earned
            # by a replaced registration must not satisfy this call's wait — the
            # server may reject the new command (e.g. permissions revoked since),
            # and returning on the stale entry would report success while leaving a
            # poisoned registration no wait can ever roll back. Snapshotting the
            # current generation (the wait accepts only a NEWER one) enforces that
            # WITHOUT deleting the entry: the server-side subscription genuinely
            # persists across a same-session replacement, so `patterns` /
            # `subscribed?` keep reporting it, and a failed call's rollback leaves
            # no observable dent (deleting here made a timed-out re-subscribe
            # under-report the still-subscribed pattern until its late ack finally
            # healed it). Re-subscribing an already-subscribed pattern is re-acked
            # promptly, minting the fresh generation.
            stale_confirmations[pattern] = @confirmed[pattern]
          end
          # Sequenced HERE — the same locked section as the write — so batch age
          # reflects true wire order for both call kinds (a marker sequenced in a
          # later section could be overtaken by a concurrent caller's write).
          issue_seq = (@issue_seq += 1)
          @inflight_waits[issue_seq] = patterns.uniq unless listener_thread?
          if listening?
            if write_to_session(:psubscribe, patterns)
              track_pending_acks(patterns, issue_seq)
            else
              # The listener session is down (likely parked in a reconnect backoff
              # that can far outlast our confirmation wait): wake it to attempt the
              # reconnect NOW. If the server is back, the replay covers this pattern
              # within the wait; if it is genuinely unreachable, the wait below times
              # out and the rollback keeps caller and server state consistent.
              @reconnect_now = true
              @cond.broadcast
            end
          else
            # A dead listener (exhausted reconnect schedule) still has every prior
            # registration in @handlers: restart with the COMPLETE registry, not just
            # the new patterns, or earlier subscriptions would silently stop receiving.
            start_listener(@handlers.keys)
          end
        end

        # Called from inside a handler, this runs on the listener thread — the only
        # thread that can read the acknowledgments — so waiting would stall delivery
        # until timeout. The command is on the wire; the acks are processed as soon
        # as the handler returns. Because nobody waits, a server rejection (e.g. an
        # ACL-forbidden pattern) can't roll back here either — the registrations are
        # marked unvalidated so a session-killing command error removes them instead
        # of poisoning every reconnect replay with the rejected pattern.
        if listener_thread?
          @lock.synchronize do
            seq = issue_seq
            patterns.each do |pattern|
              # Only mark a registration that is still the live one: a concurrent
              # replacement between the install and this lock makes ours stale, and
              # a stale marker matches no future ack and would be retained forever.
              # The `installed` hash doubles as the batch token: acks arrive in
              # command order, so a session-killing rejection is attributable to
              # the OLDEST outstanding batch — later ones survive for the replay.
              if @handlers[pattern].equal?(installed[pattern])
                @unvalidated[pattern] = { entry: installed[pattern], batch: installed, seq: seq }
              end
            end
          end
          return
        end

        begin
          wait_for_confirmation(patterns, installed, issue_seq, stale_confirmations)
        rescue StandardError
          rollback_registration(previous, installed)
          raise
        ensure
          # Resolved either way: confirmed batches were already consumed off the
          # reply stream, and failed ones are this rescue's rollback to undo —
          # attribution must stop considering them.
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

          # Capture the exact registrations this call is removing: a concurrent
          # subscribe replacing one of them mid-flight must neither be deleted from
          # the registry nor have its server-side subscription fought below. The
          # @removing marks tell the punsubscribe-ack invariant which registration
          # each ack is aimed at, so it can re-establish a replacement our command
          # killed on the wire (subscribe write ordered before our unsubscribe write).
          targets.each do |pattern|
            owned[pattern] = @handlers[pattern]
            @removing[pattern] = owned[pattern]
          end

          if listening?
            # Always the captured targets, never a blanket PUNSUBSCRIBE: with no
            # arguments the server would also drop patterns a concurrent subscribe
            # added after our capture. A false return means the session is down —
            # nothing is subscribed server-side anymore and removal is already
            # consistent; wait_for_removal falls through once the session's
            # confirmations are cleared, and a replay racing this removal is
            # reverted by the listener's registry check on its ack.
            write_to_session(:punsubscribe, targets)
          end
        end

        begin
          if listener_thread?
            # Called from inside a handler (the one-shot subscription pattern): this
            # thread is the only one that can read the acknowledgment, so waiting would
            # stall delivery until timeout. The command is on the wire — commit the
            # removal now. In-flight messages are dropped by dispatch's registry check,
            # and a replay race is reverted by the ack-time registry check.
            @lock.synchronize do
              targets.each do |pattern|
                # This call succeeded: the registrations it targeted are dead for good
                # — either deleted below or already replaced. A failed subscribe's
                # rollback must never resurrect one as "the previous registration".
                owned[pattern].failed = true
                next unless @handlers[pattern].equal?(owned[pattern])

                @handlers.delete(pattern)
                # An in-handler registration removed before its ack: purge its
                # validation entry too, or it would be retained forever.
                @unvalidated.delete(pattern) if @unvalidated[pattern]&.fetch(:entry).equal?(owned[pattern])
              end
            end
            return
          end

          wait_for_removal(targets, owned)
          @lock.synchronize do
            targets.each do |pattern|
              # This call succeeded: the registrations it targeted are dead for good
              # — either deleted below or already replaced. A failed subscribe's
              # rollback must never resurrect one as "the previous registration".
              owned[pattern].failed = true
              next unless @handlers[pattern].equal?(owned[pattern])

              @handlers.delete(pattern)
              # An in-handler registration removed before its ack: purge its
              # validation entry too, or it would be retained forever.
              @unvalidated.delete(pattern) if @unvalidated[pattern]&.fetch(:entry).equal?(owned[pattern])
            end
            # A reconnect replay may have re-subscribed a target between the ack and
            # this removal; sweep anything still acknowledged that no registration owns.
            sweep = targets.select { |pattern| @confirmed.key?(pattern) && !@handlers.key?(pattern) }
            punsubscribe_quietly(sweep)
          end
        ensure
          # Late acks (after a timeout raise, or after this call finished) are then
          # judged purely by the live registry: a still-registered pattern gets
          # re-established by the ack invariant instead of matching a stale mark.
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
        # Synchronized like every other piece of shared state: an unsynchronized
        # write has no happens-before edge with the background threads' reads, so
        # a non-GVL runtime could keep invoking the replaced handler indefinitely.
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
      # connection is down or acknowledgments are in flight; reconciliation
      # (e.g. the cluster manager's per-node catch-up) must compare against this,
      # or an obsolete registration invisible to {#patterns} survives replays.
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
        # Synchronized like every other piece of shared state: without the
        # happens-before edge a non-GVL runtime could report a torn-down manager
        # as live after close returned (NodeListener#healthy? relies on this).
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
          # Wake a listener parked in a reconnect backoff — closing the socket can't
          # interrupt a plain sleep, and a 30s delay would outlive the bounded joins.
          @cond.broadcast
          @thread
        end

        begin
          @redis.punsubscribe if thread&.alive? && @redis.subscribed?
        rescue StandardError
          nil # the listener may be mid-teardown; the force-close below covers it
        end

        if thread && !thread.equal?(Thread.current) && !thread.join(timeout)
          force_close_redis
          thread.join(timeout)
        end

        force_close_redis
        # Written under @lock (paired with closed?'s synchronized read) so the
        # closed state is visible to other threads the moment close returns.
        @lock.synchronize { @closed = true }
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
      # when close begins or when a subscribe requests an immediate reconnect
      # (spurious wakeups from ack broadcasts just resume waiting).
      # Returns false when the manager is closing.
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

      def start_listener(patterns)
        @listener_error = nil
        @thread = Thread.new { run_listener(patterns) }
        @thread.name = "redis-keyspace-notifications"
      end

      def run_listener(patterns)
        attempts = 0
        reconnecting = false

        loop do
          @session_confirmed = false
          begin
            listen(patterns, reconnecting)
            # Clean termination: every pattern unsubscribed, or close. One exception —
            # a subscription that replaced (or arrived alongside) the final
            # unsubscribe: the loop exits on the punsubscribe ack (count 0) without
            # ever reading the replacement's ack, so a registration here that is NOT
            # the removal's own target means "start a fresh session", not "done".
            # The ownership check must compare REGISTRATIONS, not patterns: an
            # unsubscribing thread deletes its entry only after this very ack woke
            # it, so its target legitimately lingers (skip it — replaying would
            # resubscribe what was just removed), while a replacement under the same
            # pattern is a different registration that must be replayed — its waiter
            # may already have returned on the replaced entry's confirmation, leaving
            # this recheck as the only actor that can revive it.
            patterns = @lock.synchronize do
              @handlers.reject { |pattern, entry| entry.equal?(@removing[pattern]) }.keys
            end
            break if patterns.empty? || @closing

            reconnecting = false
            attempts = 0
            next
          rescue StandardError => error
            break if @closing

            # The subscription loop bypasses Redis::Client's rescue wrappers, so
            # redis-client errors surface untranslated here.
            error = translate_error(error)
            if error.is_a?(CommandError)
              # The server rejected a command on this session — most likely a pattern
              # subscribed from inside a handler (nobody could wait for its ack, so
              # nobody could roll it back). Replies arrive in command order, so every
              # earlier command's acks already validated (and removed) their markers:
              # the OLDEST remaining batch is the rejected command. Drop only it —
              # later batches may be perfectly valid and get replayed; a later poison
              # is identified the same way one session later.
              @lock.synchronize do
                # min_by seq, NOT map order: a re-marked pattern keeps its
                # original Hash position, which would misattribute the rejection
                # to the newer batch and kill a valid replacement.
                oldest_marker = @unvalidated.values.min_by { |record| record[:seq] }
                # A blocking subscribe older than every in-handler batch is still
                # unresolved: the rejected command is (or may be) THAT one, and its
                # own waiter observes this error via the epoch and rolls it back.
                # Dropping the oldest in-handler batch instead would kill a valid
                # registration the rejection never touched.
                oldest_wait = @inflight_waits.keys.min
                if oldest_marker && (oldest_wait.nil? || oldest_marker[:seq] < oldest_wait)
                  oldest_batch = oldest_marker[:batch]
                  @unvalidated.each do |pattern, record|
                    next unless record[:batch].equal?(oldest_batch)

                    # Dead for good WHETHER OR NOT it is still the live entry: the
                    # server rejected this batch's command. A concurrent blocking
                    # re-subscribe of the same pattern that replaced this entry
                    # shares the session error and rolls back — without the mark,
                    # its rollback would restore the rejected entry as "the
                    # previous registration" and poison every reconnect replay.
                    record[:entry].failed = true
                    @handlers.delete(pattern) if @handlers[pattern].equal?(record[:entry])
                  end
                  @unvalidated.delete_if { |_, record| record[:batch].equal?(oldest_batch) }
                end
              end
            end
            @lock.synchronize do
              @listener_error = error
              # Waits compare against this epoch to tell a FRESH error (arrived after
              # the wait began — the waiter's command was on the killed session) from
              # a STALE one left over from before they even started.
              @listener_error_epoch += 1
              # The session's server-side subscriptions died with it: clear the
              # confirmations BEFORE the error reaches user code, so `patterns` /
              # `subscribed?` (and the cluster wrapper's health checks, which a
              # reactive refresh may consult during the callback) never report the
              # dead session as live. Pending acks die with the session too.
              @confirmed.clear
              @pending_acks.clear
              @cond.broadcast
            end
            report_error(error)
          ensure
            # Clean exits pass through here too; for error exits this repeats the
            # clear above as a no-op.
            @lock.synchronize do
              @confirmed.clear
              @pending_acks.clear
              @cond.broadcast
            end
          end

          attempts = 0 if @session_confirmed # the previous session was healthy; fresh budget
          delay = @reconnect_attempts[attempts]
          attempts += 1
          break if delay.nil? # the reconnect schedule is exhausted
          break unless interruptible_backoff(delay) # close woke us mid-delay

          patterns = @lock.synchronize { @handlers.keys }
          break if patterns.empty? || @closing

          reconnecting = true
        end
      ensure
        @lock.synchronize do
          @confirmed.clear
          @pending_acks.clear
          @cond.broadcast
        end
      end

      def listen(patterns, reconnected)
        # The reconnect hook is documented to run AFTER the manager re-subscribed:
        # fire it once every replayed pattern is either confirmed or no longer
        # registered (unregistered acks are reverted and must not count as "live").
        announce_pending = reconnected ? patterns.dup : nil
        # The session-opening command is one psubscribe per pattern, acknowledged
        # like any later one: record the expected acks before issuing it (a failed
        # connect raises into run_listener, whose session-end clear discards them).
        # The session sequence is bumped alongside: waits key their single re-issue
        # to it, and bumping before the connect lets a wait that sampled the old
        # session retry against this one.
        @lock.synchronize { @session_seq += 1 }
        track_pending_acks(patterns)
        @redis.psubscribe(*patterns) do |on|
          on.psubscribe do |pattern, _count|
            key = pattern.b
            registered = false
            pending = false
            announce = false
            @lock.synchronize do
              @session_confirmed = true
              # The listener demonstrably recovered: a stale error from a previous
              # session must not be re-raised by a later wait on a clean exit.
              @listener_error = nil
              # Consume the OLDEST expected acknowledgment: replies arrive in
              # command order, so the shifted token names exactly the command this
              # ack answers. Its blocking batch is credited on EVERY ack, gated or
              # not — a batch whose own acknowledgments were all consumed can no
              # longer be the rejected command and must retire from rejection
              # attribution immediately; retiring only on final acks would let an
              # overlapping younger command's unread ack keep an already-
              # acknowledged batch in @inflight_waits as a possible culprit,
              # shielding the genuinely-poisoned younger batch for a session
              # bounce.
              tokens = @pending_acks[key]
              token = tokens&.shift
              @pending_acks.delete(key) if tokens && tokens.empty?
              if token && (awaiting = @inflight_waits[token])
                awaiting.delete(key)
                @inflight_waits.delete(token) if awaiting.empty?
              end
              # In-handler batches retire their validation markers the same way —
              # on THEIR OWN command's ack, not the pattern's final one: an
              # overlapping younger command's unread ack must not keep a fully
              # acknowledged batch attributable, or a later rejection gets blamed
              # on the acked batch (marking its valid registration dead for
              # rollbacks) while the real poison survives the drop.
              marker = @unvalidated[key]
              @unvalidated.delete(key) if marker && token && marker[:seq] == token
              # While more acknowledgments remain, this ack answers an EARLIER
              # command than the pattern's newest one and resolves nothing
              # pattern-wide: confirming here would let a caller's wait return
              # success for a later command the server may still reject (leaving a
              # poisoned registration no wait can roll back), and retiring another
              # command's validation marker here would hide that later command
              # from rejection attribution.
              pending = tokens ? !tokens.empty? : false
              next if pending

              # Any final ack for this pattern retires its validation marker: a
              # marker matching the live registration is now validated; one that
              # doesn't match is stale (its registration was replaced or removed)
              # and would otherwise be retained forever.
              @unvalidated.delete(key)
              if @handlers.key?(key)
                # A fresh generation per final ack: re-subscribing callers' waits
                # compare against their install-time snapshot, so only this — an
                # acknowledgment consumed AFTER their install — satisfies them.
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
            # The server confirmed a pattern nobody is registered for anymore (an
            # unsubscribe or a rolled-back subscribe raced this ack): revert it so
            # server state converges back to the registry. A pending (non-final)
            # ack resolved nothing above and must not be reverted either — the
            # pattern's newest command is still awaiting its own ack.
            revert_subscription(pattern) unless registered || pending
            fire_reconnect if announce
          end
          on.punsubscribe do |pattern, _count|
            key = pattern.b
            still_wanted = @lock.synchronize do
              @confirmed.delete(key)
              @cond.broadcast
              entry = @handlers[key]
              # Wanted again unless this ack answers the unsubscribe that targets the
              # live registration (the normal flow, where deletion follows the ack).
              !entry.nil? && !entry.equal?(@removing[key])
            end
            # A registered pattern lost its server-side subscription to an unsubscribe
            # aimed at an older, since-replaced registration (the two block-less writes
            # crossed on the wire): re-establish it.
            psubscribe_quietly([pattern]) if still_wanted
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
          # In-flight messages for a pattern that is no longer registered (it is
          # being unsubscribed) are dropped rather than leaked to the default handler.
          entry = @handlers[key]
          entry ? (entry.handler || @default_handler) : nil
        end
        handler&.call(notification)
      rescue StandardError => error
        report_error(error)
      end

      # Waits for every pattern that is still THIS call's to confirm. A pattern whose
      # registration was removed or replaced by a concurrent operation stops being
      # waited for — it resolves to that operation's outcome, and timing out on it
      # would make the rollback tear down the batch's innocent siblings (the cluster
      # catch-up batches a node's whole registry, so one racing unsubscribe would
      # otherwise fail the entire node refresh).
      def wait_for_confirmation(patterns, installed, issue_seq, stale_confirmations)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBSCRIBE_ACK_TIMEOUT
        restarted = false
        reissued_session = nil
        @lock.synchronize do
          # Only errors NEWER than this wait implicate its command: a stale
          # CommandError persists until the reconnect replay confirms, and raising
          # it to a valid subscribe issued during that window would falsely reject
          # a pattern the killed session never saw.
          entry_epoch = @listener_error_epoch
          until patterns.all? { |pattern| confirmed_or_replaced?(pattern, installed, stale_confirmations) }
            # A fresh CommandError means the server REJECTED a command on this
            # session (e.g. an ACL-forbidden pattern): retrying cannot fix it, so
            # raise it promptly — the caller's rollback then removes the poisoned
            # registration instead of the replay churning until the generic timeout.
            # The session rejection is indivisible, so every waiter that shared the
            # session gets it; their rolled-back subscriptions are safe to retry.
            if (rejection = @listener_error).is_a?(CommandError) && @listener_error_epoch > entry_epoch
              raise rejection
            end

            unless listening?
              raise @listener_error if @listener_error && @listener_error_epoch > entry_epoch
              if @closing || @closed || restarted || @handlers.empty?
                raise SubscriptionError, "keyspace notifications listener died before confirming"
              end

              # The previous listener ended naturally (e.g. a racing unsubscribe-all);
              # restart it once with everything still registered.
              start_listener(@handlers.keys)
              restarted = true
            end

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise SubscriptionError, "timed out waiting for subscription confirmation" if remaining <= 0

            @cond.wait([remaining, 0.05].min)
            # At most ONE re-issue per listener session — not per 50ms wake. The
            # re-issue exists to cover the session-establishment window (a pattern
            # registered after the replay snapshot was taken has no command on the
            # new session); on a live session whose command simply hasn't been
            # acked yet, retrying is not only useless but harmful: every duplicate
            # adds a pending acknowledgment the final-ack gate must drain, and a
            # delayed listener would see confirmation recede behind an ever-growing
            # backlog of the wait's own retries. Marked only when the write
            # actually went out — an attempt against a still-connecting session is
            # retried on the next wake.
            if @session_seq != reissued_session &&
               reissue_unconfirmed(patterns, installed, issue_seq, stale_confirmations)
              reissued_session = @session_seq
            end
          end
        end
        nil
      end

      # Re-issues psubscribe for patterns the server hasn't acked yet. Covers the
      # window where a pattern was registered while the listener session wasn't
      # established (thread starting up, or between reconnect attempts). Subscribing
      # to an already-subscribed pattern is harmless — the server just re-acks it.
      # Patterns removed from the registry in the meantime are skipped.
      # Returns whether the command actually went out on the session.
      # The re-issue carries its batch's seq: when the original write was lost
      # with its session, the re-issue IS the batch's command, and its acks must
      # credit the batch's retirement from rejection attribution.
      def reissue_unconfirmed(patterns, installed, issue_seq, stale_confirmations)
        unconfirmed = patterns.select do |pattern|
          @handlers[pattern].equal?(installed[pattern]) && !fresh_confirmation?(pattern, stale_confirmations)
        end
        psubscribe_quietly(unconfirmed, issue_seq)
      end

      # A pattern stops being waited for once its confirmation generation is
      # newer than the caller's install-time snapshot, or once its registration
      # was replaced/removed by a concurrent operation (it then resolves to that
      # operation's outcome). Called under @lock.
      def confirmed_or_replaced?(pattern, installed, stale_confirmations)
        fresh_confirmation?(pattern, stale_confirmations) || !@handlers[pattern].equal?(installed[pattern])
      end

      # Whether the pattern's confirmation was minted AFTER the caller's install
      # (the install snapshots the generation it saw). A kept-but-stale entry —
      # the replaced registration's — reports the pattern as subscribed to the
      # world, but must not satisfy the replacing call's wait. Called under @lock.
      def fresh_confirmation?(pattern, stale_confirmations)
        confirmation = @confirmed[pattern]
        !confirmation.nil? && confirmation != stale_confirmations[pattern]
      end

      # Blocks until the server no longer acknowledges any still-owned target as
      # subscribed. The confirmations arrive via on.punsubscribe acks; a dead or
      # restarting session counts as removed because its confirmations are cleared
      # (server-side subscriptions die with the connection). A target whose
      # registration was replaced by a concurrent subscribe stops being waited for —
      # it is that subscribe's to confirm, and fighting it would just duel.
      def wait_for_removal(patterns, owned)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBSCRIBE_ACK_TIMEOUT
        @lock.synchronize do
          until patterns.none? { |pattern| @confirmed.key?(pattern) && @handlers[pattern].equal?(owned[pattern]) }
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              # Clear the removal marks ATOMICALLY with the timeout decision: after
              # this raise the registration stays (caller retries), so a late ack
              # must see no mark and re-establish it — releasing the lock between
              # the raise and a separate mark-clearing would let that ack slip
              # through with stale ownership and leave the pattern deaf.
              patterns.each { |pattern| @removing.delete(pattern) if @removing[pattern].equal?(owned[pattern]) }
              raise SubscriptionError, "timed out waiting for unsubscription confirmation"
            end

            @cond.wait([remaining, 0.05].min)
            pending = patterns.select do |pattern|
              @confirmed.key?(pattern) && @handlers[pattern].equal?(owned[pattern])
            end
            punsubscribe_quietly(pending)
          end
        end
        nil
      end

      # Mirror of reissue_unconfirmed for the removal path.
      def punsubscribe_quietly(patterns)
        return if patterns.empty? || !@redis.subscribed?

        write_to_session(:punsubscribe, patterns)
      end

      def psubscribe_quietly(patterns, batch_seq = nil)
        return false if patterns.empty? || !@redis.subscribed?

        written = write_to_session(:psubscribe, patterns)
        track_pending_acks(patterns, batch_seq) if written
        written
      end

      # Records one expected acknowledgment per pattern for a psubscribe command
      # that went out on the live session, remembering WHICH command it was: the
      # issuing blocking batch's seq, or nil for writes with no waiting batch
      # (the session-opening command, in-handler subscribes, re-establishes).
      # EVERY psubscribe write must pass through here: an untracked command's ack
      # would be credited to another command's token and un-gate a confirmation
      # or retire a batch early.
      def track_pending_acks(patterns, batch_seq = nil)
        @lock.synchronize do
          patterns.each { |pattern| (@pending_acks[pattern.b] ||= []) << batch_seq }
        end
      end

      # Every block-less write onto the subscription socket races its teardown:
      # between any subscribed? check and the write, the session can close under us.
      # That surfaces as SubscriptionError (no session), a connection error (socket
      # died), or — when redis-client's PubSub has already discarded its raw
      # connection — a NoMethodError on nil. All three mean the same thing here:
      # the session is gone, and the registry replay plus the ack-time invariants
      # own convergence. Returns false in that case, true when the write went out.
      def write_to_session(verb, patterns)
        @redis.public_send(verb, *patterns)
        true
      rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
        false
      rescue NoMethodError => error
        # NoMethodError#receiver raises ArgumentError when the error carries no
        # receiver information (e.g. manually constructed) — treat that as "not
        # the torn-down-connection shape" and re-raise.
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
      # manage to confirm in the meantime. Acks that arrive even later are reverted
      # by the listener's registry check.
      def rollback_registration(previous, installed)
        revert = []
        @lock.synchronize do
          previous.each do |pattern, entry|
            # This call failed, so its registration is dead wherever it ends up —
            # marking it prevents a concurrent failed subscribe's rollback from
            # restoring it as "the previous registration".
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
        # Read under @lock (paired with on_reconnect's synchronized write), called
        # outside it — user code must never run while the manager lock is held.
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
