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
      Registration = Struct.new(:handler)
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
        @handlers = {}           # pattern (BINARY String) => handler (Proc, nil for default)
        @confirmed = {}          # pattern (BINARY String) => true, as acked by the server
        @default_handler = nil
        @reconnect_handler = nil
        @lock = Monitor.new
        @cond = @lock.new_cond
        @thread = nil
        @listener_error = nil
        @reconnect_now = false
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
          end
          if listening?
            begin
              @redis.psubscribe(*patterns)
            rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
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
        # as the handler returns.
        return if listener_thread?

        begin
          wait_for_confirmation(patterns)
        rescue StandardError
          rollback_registration(previous, installed)
          raise
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
          # the registry nor have its server-side subscription fought below.
          targets.each { |pattern| owned[pattern] = @handlers[pattern] }

          if listening?
            begin
              @redis.punsubscribe(*patterns)
            rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
              # The listener session is down, so nothing is subscribed server-side
              # anymore and removal is already consistent; wait_for_removal falls
              # through once the session's confirmations are cleared. A replay racing
              # this removal is reverted by the listener's registry check on its ack.
            end
          end
        end

        if listener_thread?
          # Called from inside a handler (the one-shot subscription pattern): this
          # thread is the only one that can read the acknowledgment, so waiting would
          # stall delivery until timeout. The command is on the wire — commit the
          # removal now. In-flight messages are dropped by dispatch's registry check,
          # and a replay race is reverted by the ack-time registry check.
          @lock.synchronize do
            targets.each { |pattern| @handlers.delete(pattern) if @handlers[pattern].equal?(owned[pattern]) }
          end
          return
        end

        wait_for_removal(targets, owned)
        @lock.synchronize do
          targets.each { |pattern| @handlers.delete(pattern) if @handlers[pattern].equal?(owned[pattern]) }
          # A reconnect replay may have re-subscribed a target between the ack and
          # this removal; sweep anything still acknowledged that no registration owns.
          sweep = targets.select { |pattern| @confirmed.key?(pattern) && !@handlers.key?(pattern) }
          punsubscribe_quietly(sweep)
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
        @error_handler = block
        nil
      end

      # Called (on the listener thread) after the manager re-established a lost
      # connection and re-subscribed. Notifications emitted during the gap are lost;
      # use this to reconcile (e.g. invalidate caches).
      def on_reconnect(&block)
        @reconnect_handler = block
        nil
      end

      # @return [Array<String>] the patterns currently confirmed by the server
      def patterns
        @lock.synchronize { @confirmed.keys }
      end

      # @return [Boolean] whether the listener is running with at least one confirmed pattern
      def subscribed?
        @lock.synchronize { listening? && !@confirmed.empty? }
      end

      # @return [Boolean]
      def closed?
        @closed
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
        @closed = true
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
            # a handler that unsubscribed the final pattern and registered a
            # replacement before returning: the loop exits on the punsubscribe ack
            # (count 0) without ever reading the replacement's ack, so a non-empty
            # registry here means "start a fresh session", not "done".
            patterns = @lock.synchronize { @handlers.keys }
            break if patterns.empty? || @closing

            reconnecting = false
            attempts = 0
            next
          rescue StandardError => error
            break if @closing

            # The subscription loop bypasses Redis::Client's rescue wrappers, so
            # redis-client errors surface untranslated here.
            error = translate_error(error)
            @lock.synchronize { @listener_error = error }
            report_error(error)
          ensure
            # The session is over either way and its server-side subscriptions died
            # with it: report only what the server currently acknowledges.
            @lock.synchronize do
              @confirmed.clear
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
          @cond.broadcast
        end
      end

      def listen(patterns, reconnected)
        announce_reconnect = reconnected
        @redis.psubscribe(*patterns) do |on|
          on.psubscribe do |pattern, _count|
            key = pattern.b
            registered = @lock.synchronize do
              @session_confirmed = true
              # The listener demonstrably recovered: a stale error from a previous
              # session must not be re-raised by a later wait on a clean exit.
              @listener_error = nil
              next false unless @handlers.key?(key)

              @confirmed[key] = true
              @cond.broadcast
              true
            end
            # The server confirmed a pattern nobody is registered for anymore (an
            # unsubscribe or a rolled-back subscribe raced this ack): revert it so
            # server state converges back to the registry.
            revert_subscription(pattern) unless registered
            if announce_reconnect
              announce_reconnect = false
              fire_reconnect
            end
          end
          on.punsubscribe do |pattern, _count|
            @lock.synchronize do
              @confirmed.delete(pattern.b)
              @cond.broadcast
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
          # In-flight messages for a pattern that is no longer registered (it is
          # being unsubscribed) are dropped rather than leaked to the default handler.
          entry = @handlers[key]
          entry ? (entry.handler || @default_handler) : nil
        end
        handler&.call(notification)
      rescue StandardError => error
        report_error(error)
      end

      def wait_for_confirmation(patterns)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBSCRIBE_ACK_TIMEOUT
        restarted = false
        @lock.synchronize do
          until patterns.all? { |pattern| @confirmed.key?(pattern) }
            unless listening?
              raise @listener_error if @listener_error
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
            reissue_unconfirmed(patterns)
          end
        end
        nil
      end

      # Re-issues psubscribe for patterns the server hasn't acked yet. Covers the
      # window where a pattern was registered while the listener session wasn't
      # established (thread starting up, or between reconnect attempts). Subscribing
      # to an already-subscribed pattern is harmless — the server just re-acks it.
      # Patterns removed from the registry in the meantime are skipped.
      def reissue_unconfirmed(patterns)
        unconfirmed = patterns.select { |pattern| @handlers.key?(pattern) && !@confirmed.key?(pattern) }
        return if unconfirmed.empty? || !@redis.subscribed?

        @redis.psubscribe(*unconfirmed)
      rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
        nil
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
            raise SubscriptionError, "timed out waiting for unsubscription confirmation" if remaining <= 0

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

        @redis.punsubscribe(*patterns)
      rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
        nil
      end

      # A raised subscribe must leave no trace: restore each pattern's previous
      # registration exactly, and revert any newly-added pattern the server did
      # manage to confirm in the meantime. Acks that arrive even later are reverted
      # by the listener's registry check.
      def rollback_registration(previous, installed)
        revert = []
        @lock.synchronize do
          previous.each do |pattern, entry|
            # Re-registered by a concurrent subscribe meanwhile: theirs, not ours.
            next unless @handlers[pattern].equal?(installed[pattern])

            if entry
              @handlers[pattern] = entry[:entry]
            else
              @handlers.delete(pattern)
              revert << pattern if @confirmed.key?(pattern)
            end
          end
        end
        return if revert.empty?

        begin
          @redis.punsubscribe(*revert)
        rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
          nil
        end
      end

      # Best-effort punsubscribe of a single server-confirmed but unregistered
      # pattern (called from the listener thread's ack handling).
      def revert_subscription(pattern)
        @redis.punsubscribe(pattern)
      rescue SubscriptionError, BaseConnectionError, RedisClient::ConnectionError
        nil
      end

      def fire_reconnect
        @reconnect_handler&.call
      rescue StandardError => error
        report_error(error)
      end

      def report_error(error)
        handler = @error_handler
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
