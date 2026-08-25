# frozen_string_literal: true

require "helper"

# Exercises the manager's dispatch and lifecycle mechanics fully end to end: every
# notification consumed here is emitted by the server itself in response to real key
# modifications (`notify-keyspace-events` is enabled in setup and restored in
# teardown). The test database is 15, so events land on `__keyspace@15__` channels.
# Wire-format coverage across all six channel families lives in
# test/redis/keyspace_notifications_test.rb; malformed-payload parsing is covered by
# the parser unit tests (the server never emits malformed notifications on its own).
class TestKeyspaceNotificationsManager < Minitest::Test
  include Helper::Client

  CHANNELS = Redis::KeyspaceNotifications::Channels

  def setup
    super
    @original_flags = r.config(:get, "notify-keyspace-events")["notify-keyspace-events"]
    r.config(:set, "notify-keyspace-events", "KEA")
    @managers = []
  end

  def teardown
    @managers.each do |manager|
      manager.close
    rescue StandardError
      nil
    end
    r.config(:set, "notify-keyspace-events", @original_flags || "")
    super
  end

  def test_dispatches_typed_notification_to_pattern_handler
    queue = Queue.new
    manager = new_manager
    channel = CHANNELS.keyspace("mykey", db: DB)
    manager.subscribe(channel, handler: ->(notification) { queue << notification })

    r.set("mykey", "value")

    notification = assert_pop(queue)
    assert_equal :keyspace, notification.family
    assert_equal DB, notification.db
    assert_equal "set", notification.event
    assert_equal "mykey", notification.key
    assert_equal channel, notification.pattern
  end

  def test_typed_subscription_helpers
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent("del", db: DB) { |notification| queue << notification }

    r.set("doomed", "value")
    r.del("doomed")

    notification = assert_pop(queue)
    assert_equal :keyevent, notification.family
    assert_equal DB, notification.db
    assert_equal "del", notification.event
    assert_equal "doomed", notification.key
  end

  def test_pattern_subscription_receives_matching_channels
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyspace("user:*", db: DB) { |notification| queue << notification }

    r.set("user:42", "v")

    notification = assert_pop(queue)
    assert_equal "user:42", notification.key
    assert_equal "set", notification.event
    assert_equal CHANNELS.keyspace("user:*", db: DB), notification.pattern
  end

  def test_default_handler_receives_unrouted_patterns
    queue = Queue.new
    manager = new_manager
    manager.on_notification { |notification| queue << notification }
    manager.subscribe(CHANNELS.keyevent("del", db: DB))

    r.set("somekey", "v")
    r.del("somekey")

    assert_equal "somekey", assert_pop(queue).key
  end

  def test_error_handler_receives_non_notification_messages_and_loop_survives
    notifications = Queue.new
    errors = Queue.new
    manager = new_manager(error_handler: ->(error) { errors << error })
    # A manager pointed at an ordinary pub/sub channel: real messages arriving there
    # are not notifications — reported as ParseError, and the listener keeps going.
    manager.subscribe("app-events:*", handler: ->(notification) { notifications << notification })
    manager.subscribe_keyspace("realkey", db: DB) { |notification| notifications << notification }

    r.publish("app-events:deploy", "hello")

    error = assert_pop(errors)
    assert_instance_of Redis::KeyspaceNotifications::ParseError, error
    assert_equal "app-events:deploy", error.channel

    r.set("realkey", "v")

    assert_equal "realkey", assert_pop(notifications).key
  end

  def test_error_handler_receives_handler_exceptions_and_loop_survives
    errors = Queue.new
    notifications = Queue.new
    manager = new_manager(error_handler: ->(error) { errors << error })
    calls = 0
    manager.subscribe_keyspace("flaky", db: DB) do |notification|
      calls += 1
      raise "boom" if calls == 1

      notifications << notification
    end

    r.set("flaky", "v") # first event: handler raises

    assert_equal "boom", assert_pop(errors).message

    r.del("flaky") # second event: loop survived, handler works again

    assert_equal "del", assert_pop(notifications).event
  end

  def test_subscribe_blocks_until_confirmed
    queue = Queue.new
    manager = new_manager
    manager.subscribe(CHANNELS.keyspace("confirmed", db: DB), handler: ->(notification) { queue << notification })

    # Notifications are fire-and-forget: if subscribe had returned before the server
    # registered the pattern, the event of this write could be lost.
    r.set("confirmed", "v")

    assert_equal "set", assert_pop(queue).event
  end

  def test_dynamic_subscribe_and_unsubscribe_while_running
    queue = Queue.new
    channel_a = CHANNELS.keyspace("a", db: DB)
    channel_b = CHANNELS.keyspace("b", db: DB)
    manager = new_manager
    manager.subscribe(channel_a, handler: ->(notification) { queue << notification })
    manager.subscribe(channel_b, handler: ->(notification) { queue << notification })

    r.set("b", "v")

    assert_equal "b", assert_pop(queue).key

    manager.unsubscribe(channel_b)

    # Unsubscribe blocked until the server acked, so this write emits nothing to us;
    # the next delivery must be a's (a stale b event would arrive first if it existed).
    r.set("b", "v2")
    r.set("a", "v")

    assert_equal "a", assert_pop(queue).key
    assert_predicate queue, :empty?
    assert_equal [channel_a], manager.patterns
  end

  def test_resubscribing_a_pattern_replaces_its_handler
    first = Queue.new
    second = Queue.new
    channel = CHANNELS.keyspace("k", db: DB)
    manager = new_manager
    manager.subscribe(channel, handler: ->(notification) { first << notification })
    manager.subscribe(channel, handler: ->(notification) { second << notification })

    r.set("k", "v")

    assert_equal "set", assert_pop(second).event
    assert_predicate first, :empty?
  end

  def test_unsubscribe_of_unknown_pattern_is_a_noop
    queue = Queue.new
    channel = CHANNELS.keyspace("known", db: DB)
    manager = new_manager
    manager.subscribe(channel, handler: ->(notification) { queue << notification })

    manager.unsubscribe(CHANNELS.keyspace("never-subscribed", db: DB))

    assert_equal [channel], manager.patterns
    r.set("known", "v")
    assert_equal "set", assert_pop(queue).event
  end

  def test_unsubscribing_all_stops_listener_and_resubscribe_restarts_it
    queue = Queue.new
    channel = CHANNELS.keyspace("k", db: DB)
    manager = new_manager
    manager.subscribe(channel, handler: ->(notification) { queue << notification })
    manager.unsubscribe

    assert_empty manager.patterns
    wait_until { !manager.subscribed? }

    # The server acked the removal before unsubscribe returned, so this event is
    # never sent to us — if it were, it would arrive before the del below.
    r.set("k", "v")

    manager.subscribe(channel, handler: ->(notification) { queue << notification })

    assert_predicate manager, :subscribed?
    r.del("k")

    assert_equal "del", assert_pop(queue).event
    assert_predicate queue, :empty?
  end

  def test_close_is_idempotent_and_stops_delivery
    queue = Queue.new
    manager = new_manager
    manager.subscribe(CHANNELS.keyspace("k", db: DB), handler: ->(notification) { queue << notification })
    manager.close
    manager.close

    assert_predicate manager, :closed?
    refute_predicate manager, :subscribed?
    wait_until { r.pubsub(:numpat) == 0 } # the server dropped the subscription with the connection

    r.set("k", "v")
    sleep 0.1

    assert_predicate queue, :empty?
    assert_raises(Redis::SubscriptionError) { manager.subscribe(CHANNELS.keyspace("k", db: DB)) }
  end

  def test_close_from_within_handler_does_not_deadlock
    manager = new_manager
    closed = Queue.new
    manager.subscribe(CHANNELS.keyspace("k", db: DB), handler: lambda { |_notification|
      manager.close
      closed << true
    })

    r.set("k", "v")

    assert_pop(closed)
    wait_until { manager.closed? }
    wait_until { r.pubsub(:numpat) == 0 }
  end

  def test_manager_uses_dedicated_connection
    manager = new_manager
    manager.subscribe(CHANNELS.keyspace("k", db: DB))

    refute_predicate r, :subscribed?
    assert_equal "PONG", r.ping
  end

  def test_auto_resubscribe_after_connection_loss
    notifications = Queue.new
    errors = Queue.new
    reconnected = Queue.new
    # Array form: explicit sleep durations between reconnect attempts (short, for test speed).
    manager = new_manager(error_handler: ->(error) { errors << error }, reconnect_attempts: [0.05, 0.1, 0.2])
    manager.on_reconnect { reconnected << true }
    manager.subscribe_keyspace("k", db: DB) { |notification| notifications << notification }

    r.client(:kill, "TYPE", "pubsub")

    assert_kind_of Redis::BaseConnectionError, assert_pop(errors)
    assert_pop(reconnected, timeout: 5) # fired on the re-subscription ack: the pattern is live again

    r.set("k", "v")

    assert_equal "set", assert_pop(notifications).event
  end

  def test_restarting_a_dead_listener_replays_every_registered_pattern
    queue = Queue.new
    manager = new_manager(error_handler: ->(_error) {}, reconnect_attempts: [])
    manager.subscribe(CHANNELS.keyspace("old", db: DB), handler: ->(notification) { queue << notification })

    r.client(:kill, "TYPE", "pubsub") # reconnect schedule empty: the listener dies
    wait_until { !manager.subscribed? }

    # Subscribing something new restarts the listener; the earlier registration
    # must be replayed too, not silently dropped.
    manager.subscribe(CHANNELS.keyspace("new", db: DB), handler: ->(notification) { queue << notification })

    r.set("old", "v")
    r.set("new", "v")

    assert_equal %w[new old], Array.new(2) { assert_pop(queue).key }.sort
  end

  def test_unsubscribe_from_within_handler_is_immediate
    queue = Queue.new
    elapsed = nil
    manager = new_manager
    channel = CHANNELS.keyspace("oneshot", db: DB)
    manager.subscribe(channel, handler: lambda { |notification|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      manager.unsubscribe(channel) # one-shot subscription: must not stall delivery
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      queue << notification
    })
    manager.subscribe(CHANNELS.keyspace("other", db: DB), handler: ->(notification) { queue << notification })

    r.set("oneshot", "v")

    assert_equal "oneshot", assert_pop(queue).key
    assert_operator elapsed, :<, 1, "self-unsubscribe stalled the listener thread"

    # The ack is processed right after the handler returns; the unsubscribed pattern
    # disappears from both the server and the confirmed set, the other keeps flowing.
    wait_until { r.pubsub(:numpat) == 1 }
    wait_until { manager.patterns == [CHANNELS.keyspace("other", db: DB)] }
    r.set("oneshot", "v2")
    r.set("other", "v")

    assert_equal "other", assert_pop(queue).key
    assert_predicate queue, :empty?
  end

  def test_transient_in_handler_subscription_leaves_no_residue
    queue = Queue.new
    manager = new_manager
    transient = CHANNELS.keyspace("transient", db: DB)
    manager.subscribe(CHANNELS.keyspace("trigger", db: DB), handler: lambda { |notification|
      # Subscribe and unsubscribe within one handler: neither ack has been read yet,
      # so the unvalidated bookkeeping must be purged by the removal, not kept forever.
      manager.subscribe(transient, handler: ->(_n) {})
      manager.unsubscribe(transient)
      queue << notification
    })

    r.set("trigger", "v")

    assert_equal "trigger", assert_pop(queue).key
    wait_until { manager.instance_variable_get(:@unvalidated).empty? }
    refute_includes manager.instance_variable_get(:@handlers).keys, transient
  end

  def test_subscribe_from_within_handler_takes_effect
    queue = Queue.new
    manager = new_manager
    late = CHANNELS.keyspace("late", db: DB)
    manager.subscribe(CHANNELS.keyspace("first", db: DB), handler: lambda { |notification|
      manager.subscribe(late, handler: ->(n) { queue << n }) unless manager.patterns.include?(late)
      queue << notification
    })

    r.set("first", "v")

    assert_equal "first", assert_pop(queue).key
    wait_until { r.pubsub(:numpat) == 2 } # the in-handler subscription reached the server
    r.set("late", "v")

    assert_equal "late", assert_pop(queue).key
  end

  def test_replacing_the_last_subscription_from_within_a_handler
    queue = Queue.new
    manager = new_manager
    first = CHANNELS.keyspace("swap:first", db: DB)
    second = CHANNELS.keyspace("swap:second", db: DB)
    manager.subscribe(first, handler: lambda { |notification|
      # Unsubscribe everything, then register a replacement before returning: the
      # session ends on the punsubscribe ack, but the listener must restart for
      # the replacement instead of treating it as a clean shutdown.
      manager.unsubscribe
      manager.subscribe(second, handler: ->(n) { queue << n })
      queue << notification
    })

    r.set("swap:first", "v")

    assert_equal "swap:first", assert_pop(queue).key
    wait_until { manager.patterns == [second] }

    r.set("swap:second", "v")

    assert_equal "swap:second", assert_pop(queue).key
  end

  def test_concurrent_unsubscribe_and_resubscribe_stay_consistent
    channel = CHANNELS.keyspace("race", db: DB)
    manager = new_manager

    10.times do
      queue = Queue.new
      manager.subscribe(channel, handler: ->(notification) { queue << notification })

      unsubscriber = Thread.new do
        manager.unsubscribe(channel)
      rescue Redis::SubscriptionError
        nil
      end
      begin
        manager.subscribe(channel, handler: ->(notification) { queue << notification })
      rescue Redis::SubscriptionError
        nil # rolled back: the concurrent unsubscribe won
      end
      unsubscriber.join

      # Concurrent subscribe/unsubscribe of one pattern has no defined winner; the
      # contract is convergence — the server-side subscription must agree with the
      # local registration (the ack-time invariants repair wire-order races), and
      # delivery must agree with both. Settled means ALL THREE layers agree —
      # registry (intent), confirmed (acked) and the server — otherwise a re-issue
      # can still be in flight while confirmed and NUMPAT momentarily read empty.
      registered = nil
      settle_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      loop do
        registry = manager.instance_variable_get(:@handlers).keys
        confirmed = manager.patterns
        registered = registry == [channel]
        break if (registry.empty? || registered) && registry.sort == confirmed.sort &&
                 r.pubsub(:numpat) == registry.size

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > settle_deadline
          thread = manager.instance_variable_get(:@thread)
          flunk "never settled: registry=#{registry.inspect} confirmed=#{confirmed.inspect} " \
                "numpat=#{r.pubsub(:numpat)} removing=#{manager.instance_variable_get(:@removing).keys.inspect} " \
                "listener=#{thread&.status.inspect} top=#{thread&.backtrace&.first.inspect}"
        end
        sleep 0.01
      end
      if registered
        # The settled subscription must deliver — but a single probe can be lost:
        # an unsubscribe aimed at a replaced registration may still be in flight
        # server-side (invisible to every layer until it lands), and an event
        # published into that gap is gone forever (fire-and-forget) before the
        # ack invariant re-subscribes. That loss window is inherent to pub/sub —
        # the guarantee is that the STREAM recovers, so probe with retries.
        delivered = nil
        3.times do
          r.set("race", "v")
          delivered = queue.pop(timeout: 1)
          break if delivered
        end

        flunk "no delivery despite a settled registration" unless delivered
        assert_equal "race", delivered.key
      else
        # An empty settled state stays silent: nothing re-subscribes an
        # unregistered pattern, and dispatch drops events for one regardless.
        r.set("race", "v")
        sleep 0.05

        assert_predicate queue, :empty?
      end
      manager.unsubscribe(channel)
    end
  end

  def test_subscribe_during_reconnect_backoff_triggers_immediate_reconnect
    errors = Queue.new
    # One long delay: without the immediate-reconnect wake-up, a subscribe issued
    # during this backoff could only wait out its confirmation timeout and fail,
    # even though the server is perfectly reachable again.
    manager = new_manager(error_handler: ->(error) { errors << error }, reconnect_attempts: [30])
    old_queue = Queue.new
    manager.subscribe(CHANNELS.keyspace("old", db: DB), handler: ->(notification) { old_queue << notification })

    r.client(:kill, "TYPE", "pubsub")
    assert_pop(errors) # the listener is heading into its 30s backoff

    new_queue = Queue.new
    manager.subscribe(CHANNELS.keyspace("new", db: DB), handler: ->(notification) { new_queue << notification })

    # The subscribe returned confirmed: both the replayed and the new pattern are live.
    r.set("old", "v")
    r.set("new", "v")

    assert_equal "old", assert_pop(old_queue).key
    assert_equal "new", assert_pop(new_queue).key
  end

  def test_blockless_writes_tolerate_a_torn_down_pubsub_connection
    manager = new_manager
    manager.subscribe(CHANNELS.keyspace("a", db: DB))
    internal = manager.instance_variable_get(:@redis)

    # The exact shape redis-client's PubSub produces when a concurrent session
    # teardown discarded the raw connection: `nil.write(...)`.
    torn_down = begin
      nil.write("x")
    rescue NoMethodError => error
      error
    end
    internal.stubs(:punsubscribe).raises(torn_down)

    refute manager.send(:write_to_session, :punsubscribe, ["a"]),
           "the torn-down-connection race must read as 'session gone', not raise"

    # Unrelated NoMethodErrors are real bugs and must escape: a non-nil receiver,
    # and a manually built error with no receiver information at all.
    other_receiver = begin
      Object.new.write("x")
    rescue NoMethodError => error
      error
    end
    internal.stubs(:punsubscribe).raises(other_receiver)

    assert_raises(NoMethodError) { manager.send(:write_to_session, :punsubscribe, ["a"]) }

    internal.stubs(:punsubscribe).raises(NoMethodError.new("undefined method 'write'"))

    assert_raises(NoMethodError) { manager.send(:write_to_session, :punsubscribe, ["a"]) }
  ensure
    internal&.unstub(:punsubscribe)
  end

  def test_server_rejected_subscribe_raises_promptly_and_spares_other_patterns
    r.acl("SETUSER", "kn_limited", "on", ">knpass", "+@all", "resetchannels",
          "&__keyspace@#{DB}__:allowed", "&__keyspace@#{DB}__:allowed2")
    restricted = Redis.new(OPTIONS.merge(username: "kn_limited", password: "knpass",
                                         driver: ENV["DRIVER"], protocol: PROTOCOL))
    errors = Queue.new
    manager = Redis::KeyspaceNotifications::Manager.new(redis: restricted, error_handler: ->(error) { errors << error })
    @managers << manager
    queue = Queue.new
    manager.subscribe(CHANNELS.keyspace("allowed", db: DB), handler: ->(notification) { queue << notification })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Redis::CommandError) { manager.subscribe(CHANNELS.keyspace("forbidden", db: DB)) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_match(/NOPERM|permission/i, error.message)
    assert_operator elapsed, :<, 3, "a server rejection must raise promptly, not wait out the ack timeout"

    # A VALID subscribe issued during the reconnect window (the stale CommandError
    # is still stored until the replay confirms) must not inherit the rejection:
    # only errors newer than the wait implicate its command.
    queue2 = Queue.new
    manager.subscribe(CHANNELS.keyspace("allowed2", db: DB), handler: ->(notification) { queue2 << notification })
    r.set("allowed2", "v")

    assert_equal "allowed2", assert_pop(queue2).key

    # The rejected registration was rolled back, so the reconnect replay is clean
    # and the surviving pattern recovers. The rejection killed the session, and
    # events published into the reconnect gap are lost (fire-and-forget) — NUMPAT
    # can even briefly count the dying session — so probe with retries.
    delivered = nil
    5.times do
      r.set("allowed", "v")
      delivered = queue.pop(timeout: 1)
      break if delivered
    end

    flunk "the allowed pattern did not recover after the rejection" unless delivered
    assert_equal "allowed", delivered.key
    assert_equal [CHANNELS.keyspace("allowed", db: DB), CHANNELS.keyspace("allowed2", db: DB)],
                 manager.patterns.sort
  ensure
    r.acl("DELUSER", "kn_limited")
  end

  def test_completed_unsubscribe_marks_its_registration_dead
    manager = new_manager
    channel = CHANNELS.keyspace("dead", db: DB)
    manager.subscribe(channel, handler: ->(_notification) {})
    entry = manager.instance_variable_get(:@handlers)[channel]

    manager.unsubscribe(channel)

    # rollback_registration consults this flag when restoring "the previous
    # registration": one disposed of by a completed unsubscribe (deleted, or
    # released because it was replaced) must never be resurrected by a failed
    # concurrent subscribe's rollback.
    assert entry.failed, "a completed unsubscribe must mark its captured registration dead"
  end

  def test_close_interrupts_a_reconnect_backoff
    errors = Queue.new
    # A single long delay: without an interruptible backoff, close would leave the
    # listener thread sleeping for the full 30s after its bounded joins expire.
    manager = new_manager(error_handler: ->(error) { errors << error }, reconnect_attempts: [30])
    manager.subscribe_keyspace("k", db: DB)

    r.client(:kill, "TYPE", "pubsub")
    assert_pop(errors) # the listener is now in (or entering) its backoff sleep

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    manager.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate manager, :closed?
    assert_operator elapsed, :<, 3, "close waited out the reconnect backoff"
  end

  def test_replacing_a_confirmed_pattern_waits_for_a_fresh_acknowledgment
    gate = Queue.new
    release = Queue.new
    manager = new_manager(error_handler: ->(_error) {})
    manager.subscribe(CHANNELS.keyspace("fresh", db: DB), handler: lambda { |_notification|
      gate << true
      release.pop
    })
    r.set("fresh", "v1")
    gate.pop # the listener thread is now parked inside the handler: no acks can be read

    replaced = Queue.new
    replacer = Thread.new do
      manager.subscribe(CHANNELS.keyspace("fresh", db: DB), handler: ->(n) { replaced << n })
      :done
    end
    sleep 0.2
    # The replaced registration's stale confirmation must not satisfy the
    # replacement's wait: its own ack can only be read once the listener resumes.
    # Returning early would report success for a command the server could still
    # reject, with no waiter left to roll the registration back.
    assert_predicate replacer, :alive?, "replacement subscribe returned before its acknowledgment could be read"

    release << true
    assert_equal :done, replacer.value
    r.set("fresh", "v2")

    assert_equal "fresh", assert_pop(replaced).key
  ensure
    release&.push(true)
  end

  def test_in_handler_rejection_is_attributed_by_issue_order_not_map_position
    shared = CHANNELS.keyspace("shared", db: DB)
    r.acl("SETUSER", "kn_limited2", "on", ">knpass", "+@all", "resetchannels",
          "&#{CHANNELS.keyspace('trigger', db: DB)}", "&#{shared}")
    restricted = Redis.new(OPTIONS.merge(username: "kn_limited2", password: "knpass",
                                         driver: ENV["DRIVER"], protocol: PROTOCOL))
    manager = Redis::KeyspaceNotifications::Manager.new(redis: restricted, error_handler: ->(_error) {})
    @managers << manager
    replaced = Queue.new
    fired = Queue.new
    manager.subscribe(CHANNELS.keyspace("trigger", db: DB), handler: lambda { |_notification|
      next unless fired.empty?

      fired << true
      # Batch 1: a valid pattern sharing the call with a forbidden one. Batch 2:
      # replaces the valid pattern before the handler returns. Re-marking the
      # pattern keeps its ORIGINAL map position, so position-based age would
      # blame batch 2 for batch 1's rejection — killing the valid replacement
      # and keeping the poison.
      manager.subscribe(shared, CHANNELS.keyspace("forbidden", db: DB), handler: ->(_n) {})
      manager.subscribe(shared, handler: ->(notification) { replaced << notification })
    })
    r.set("trigger", "v")
    assert fired.pop(timeout: 3)

    # The rejection bounces the session; the replacement must survive the batch
    # drop and be replayed, while the forbidden pattern is dropped for good.
    wait_until(timeout: 5) do
      manager.registered_patterns.sort == [CHANNELS.keyspace("trigger", db: DB), shared].sort
    end
    received = nil
    wait_until(timeout: 5) do
      r.set("shared", "v")
      received = replaced.pop(timeout: 0.5)
      !received.nil?
    end

    assert_equal "shared", received.key
  ensure
    begin
      r.acl("DELUSER", "kn_limited2")
    rescue StandardError
      nil
    end
  end

  def test_rejected_blocking_subscribe_is_not_blamed_on_in_handler_batches
    trigger = CHANNELS.keyspace("trigger", db: DB)
    inhandler = CHANNELS.keyspace("inhandler", db: DB)
    r.acl("SETUSER", "kn_limited3", "on", ">knpass", "+@all", "resetchannels",
          "&#{trigger}", "&#{inhandler}")
    restricted = Redis.new(OPTIONS.merge(username: "kn_limited3", password: "knpass",
                                         driver: ENV["DRIVER"], protocol: PROTOCOL))
    manager = Redis::KeyspaceNotifications::Manager.new(redis: restricted, error_handler: ->(_error) {})
    @managers << manager
    gate = Queue.new
    release = Queue.new
    received = Queue.new
    manager.subscribe(trigger, handler: lambda { |_notification|
      gate << true
      release.pop
      # Wire position 2: a VALID in-handler subscribe, issued after the caller's
      # rejected command already sits first on the wire. The session-killing
      # rejection belongs to the caller's command — which has its own waiter to
      # roll it back — so attribution must not blame (and delete) this batch.
      manager.subscribe(inhandler, handler: ->(notification) { received << notification })
    })
    r.set("trigger", "v")
    gate.pop # the listener is parked: nothing is read until release

    rejector = Thread.new do
      # Wire position 1: written immediately (writes don't need the listener),
      # rejected once the listener resumes reading.
      manager.subscribe(CHANNELS.keyspace("forbidden", db: DB))
    rescue StandardError => error
      error
    end
    sleep 0.2 # let the rejected command reach the wire before the handler's
    release << true

    assert_kind_of Redis::CommandError, rejector.value
    # The in-handler registration survives attribution, is replayed after the
    # rejection's session bounce, and delivers; the rejected pattern is rolled
    # back by its own waiter.
    wait_until(timeout: 5) do
      manager.registered_patterns.sort == [inhandler, trigger].sort && manager.subscribed?
    end
    notification = nil
    wait_until(timeout: 5) do
      r.set("inhandler", "v")
      notification = received.pop(timeout: 0.5)
      !notification.nil?
    end

    assert_equal "inhandler", notification.key
  ensure
    begin
      r.acl("DELUSER", "kn_limited3")
    rescue StandardError
      nil
    end
  end

  def test_error_handler_observes_the_dead_session_as_unsubscribed
    manager = nil
    states = Queue.new
    manager = new_manager(error_handler: lambda { |error|
      states << { error: error, subscribed: manager.subscribed?, patterns: manager.patterns }
    })
    manager.subscribe_keyspace("k", db: DB) { |_notification| }

    r.client(:kill, "TYPE", "pubsub")

    state = states.pop(timeout: 3)
    refute_nil state, "the connection loss never reached the error handler"
    assert_kind_of Redis::BaseConnectionError, state[:error]
    # The session's server-side subscriptions died with it: confirmations must be
    # cleared BEFORE the error reaches user code, or the callback (and anything it
    # consults, like the cluster wrapper's health checks) sees the dead session
    # as live.
    refute state[:subscribed], "error handler saw the dead session as subscribed"
    assert_empty state[:patterns]
  end

  def test_in_handler_rejection_after_acked_blocking_subscribe_converges_in_one_session
    trigger = CHANNELS.keyspace("trigger", db: DB)
    valid = CHANNELS.keyspace("valid", db: DB)
    r.acl("SETUSER", "kn_limited4", "on", ">knpass", "+@all", "resetchannels",
          "&#{trigger}", "&#{valid}")
    restricted = Redis.new(OPTIONS.merge(username: "kn_limited4", password: "knpass",
                                         driver: ENV["DRIVER"], protocol: PROTOCOL))
    rejections = Queue.new
    manager = Redis::KeyspaceNotifications::Manager.new(
      redis: restricted,
      error_handler: ->(error) { rejections << error if error.is_a?(Redis::CommandError) }
    )
    @managers << manager
    gate = Queue.new
    release = Queue.new
    manager.subscribe(trigger, handler: lambda { |_notification|
      gate << true
      release.pop
      # Wire order: the blocking subscribe below is acked FIRST, then this
      # rejected command errors. A fully-acknowledged blocking batch must retire
      # from rejection attribution at ack time — even while its caller has not
      # resumed — or the rejection is not attributed to this batch and the poison
      # survives into (and bounces) a second session.
      manager.subscribe(CHANNELS.keyspace("forbidden", db: DB), handler: ->(_n) {})
    })
    r.set("trigger", "v")
    gate.pop

    waiter = Thread.new do
      manager.subscribe(valid, handler: ->(_n) {})
      :ok
    rescue Redis::CommandError => error
      error # the session-rejection-is-indivisible doctrine: a raise here is legal
    end
    sleep 0.2 # the valid command reaches the wire (and is acked) ahead of the poison
    release << true

    waiter.join(5)
    # Exactly ONE rejection converges the poison out of the registry; a second one
    # means the acked wait masked the attribution and the poison was replayed.
    assert_kind_of Redis::CommandError, rejections.pop(timeout: 3)
    wait_until(timeout: 5) do
      !manager.registered_patterns.include?(CHANNELS.keyspace("forbidden", db: DB)) && manager.subscribed?
    end
    sleep 0.5 # a second rejection would need a session bounce; give it room to appear

    assert_predicate rejections, :empty?, "the poison survived into a second session"
  ensure
    begin
      r.acl("DELUSER", "kn_limited4")
    rescue StandardError
      nil
    end
  end

  def test_empty_reconnect_schedule_disables_reconnection
    queue = Queue.new
    errors = Queue.new
    manager = new_manager(error_handler: ->(error) { errors << error }, reconnect_attempts: [])
    manager.subscribe_keyspace("k", db: DB) { |notification| queue << notification }

    r.client(:kill, "TYPE", "pubsub")

    assert_kind_of Redis::BaseConnectionError, assert_pop(errors)
    wait_until { !manager.subscribed? }
    wait_until { r.pubsub(:numpat) == 0 }
    sleep 0.2 # would be enough for a first reconnect attempt if one were scheduled

    refute_predicate manager, :subscribed?
    # Intent and confirmations diverge while down: the registration survives
    # (a reconnect replay would restore it) even though nothing is confirmed.
    assert_empty manager.patterns
    assert_equal [Redis::KeyspaceNotifications::Channels.keyspace("k", db: DB)], manager.registered_patterns
    r.set("k", "v")
    sleep 0.1

    assert_predicate queue, :empty?
  end

  def test_an_earlier_commands_ack_does_not_satisfy_a_later_resubscribes_wait
    gate = Queue.new
    release = Queue.new
    manager = new_manager(error_handler: ->(_error) {})
    # A parking channel: its handler blocks the listener thread on demand, so the
    # acknowledgments piling up behind each publication are read only when we say so.
    manager.subscribe(CHANNELS.keyspace("park", db: DB), handler: lambda { |_notification|
      gate << true
      release.pop
    })
    target = CHANNELS.keyspace("generation", db: DB)
    manager.subscribe(target, handler: ->(_n) {})

    r.set("park", "v1")
    gate.pop # the listener is parked: nothing on the wire is read anymore

    first = Thread.new { manager.subscribe(target, handler: ->(_n) {}) }
    sleep 0.2 # the first re-subscribe's command (and the server's ack) is on the wire
    r.set("park", "v2") # a second parking message, ordered AFTER the first command's ack
    sleep 0.1
    replaced = Queue.new
    second = Thread.new { manager.subscribe(target, handler: ->(n) { replaced << n }) }
    sleep 0.2 # the second re-subscribe's command is on the wire, behind the parking message

    release << true # the listener consumes the first command's ack, then parks on "v2"
    gate.pop
    sleep 0.2
    # The consumed ack answered the FIRST command. The second call's own, later command
    # is still unanswered — its wait must not be satisfied by the earlier acknowledgment
    # (the server could still reject it, with no waiter left to roll the poison back).
    assert_predicate second, :alive?, "second re-subscribe returned on the first command's acknowledgment"

    release << true # the listener reads on: the second command's ack resolves the wait
    second.join(3)
    refute_predicate second, :alive?, "second re-subscribe never confirmed"
    first.join(3)

    r.set("generation", "v")
    assert_equal "generation", assert_pop(replaced).key
  ensure
    release&.push(true)
    release&.push(true)
  end

  def test_reissues_are_bounded_per_session_while_the_listener_is_delayed
    gate = Queue.new
    release = Queue.new
    manager = new_manager(error_handler: ->(_error) {})
    manager.subscribe(CHANNELS.keyspace("park", db: DB), handler: lambda { |_notification|
      gate << true
      release.pop
    })
    target = CHANNELS.keyspace("bounded", db: DB)
    manager.subscribe(target, handler: ->(_n) {})

    r.set("park", "v1")
    gate.pop # the listener is parked: acknowledgments pile up unread

    resubscriber = Thread.new { manager.subscribe(target, handler: ->(_n) {}) }
    sleep 0.6 # ~12 wait wakeups; a per-wakeup re-issue would stack a pending ack each

    pending = manager.instance_variable_get(:@lock).synchronize do
      (manager.instance_variable_get(:@pending_acks)[target.b] || []).size
    end
    # The command itself plus at most one same-session re-issue: each duplicate is
    # another acknowledgment the final-ack gate must drain, so unbounded retries
    # would keep pushing confirmation behind fresh duplicates of themselves.
    assert_operator pending, :<=, 2, "the wait stacked #{pending} pending acknowledgments"

    release << true
    resubscriber.join(3)

    refute_predicate resubscriber, :alive?, "re-subscribe never confirmed"
  ensure
    release&.push(true)
  end

  def test_acked_in_handler_batch_is_not_blamed_for_a_later_batches_rejection
    trigger = CHANNELS.keyspace("trigger", db: DB)
    x = CHANNELS.keyspace("shared", db: DB)
    y = CHANNELS.keyspace("sibling", db: DB)
    forbidden = CHANNELS.keyspace("forbidden", db: DB)
    r.acl("SETUSER", "kn_limited5", "on", ">knpass", "+@all", "resetchannels",
          "&#{trigger}", "&#{x}", "&#{y}")
    restricted = Redis.new(OPTIONS.merge(username: "kn_limited5", password: "knpass",
                                         driver: ENV["DRIVER"], protocol: PROTOCOL))
    manager = Redis::KeyspaceNotifications::Manager.new(redis: restricted, error_handler: ->(_error) {})
    @managers << manager
    fired = Queue.new
    release = Queue.new
    manager.subscribe(trigger, handler: lambda { |_notification|
      next unless fired.empty?

      # A fully valid in-handler batch, then the actual poison, then park: both
      # commands' replies are read only after the blocking call below put a
      # younger command for x on the wire.
      manager.subscribe(x, y, handler: ->(_n) {})
      manager.subscribe(forbidden, handler: ->(_n) {})
      fired << true
      release.pop
    })
    r.set("trigger", "v")
    fired.pop

    replacer = Thread.new do
      manager.subscribe(x, handler: ->(_n) {})
      :subscribed
    rescue StandardError => error
      error
    end
    sleep 0.2 # the younger x command is on the wire; the valid batch's x ack will be gated
    release << true # the listener reads the valid batch's acks, then the rejection

    # The rejection belongs to the forbidden batch. The valid batch was fully
    # acknowledged — its x ack merely arrived while the younger command was
    # pending — so it must have retired from attribution on its OWN ack: blaming
    # it would mark its x registration dead, the failing replacer's rollback
    # would then DELETE x instead of restoring it, and the poison would survive.
    assert_kind_of Redis::CommandError, replacer.value
    wait_until(timeout: 5) do
      manager.registered_patterns.sort == [trigger, x, y].sort
    end
  ensure
    release&.push(true)
    begin
      r.acl("DELUSER", "kn_limited5")
    rescue StandardError
      nil
    end
  end

  def test_failed_resubscribe_rollback_keeps_the_live_confirmation_visible
    gate = Queue.new
    release = Queue.new
    received = Queue.new
    manager = new_manager(error_handler: ->(_error) {})
    manager.subscribe(CHANNELS.keyspace("park", db: DB), handler: lambda { |_notification|
      gate << true
      release.pop
    })
    target = CHANNELS.keyspace("kept", db: DB)
    manager.subscribe(target, handler: ->(notification) { received << notification })

    r.set("park", "v1")
    gate.pop # the listener is parked: the re-subscribe below cannot be acked

    replacer = Thread.new do
      manager.subscribe(target, handler: ->(_n) {})
      :subscribed
    rescue StandardError => error
      error
    end
    sleep 0.5
    # The server-side subscription persists across a same-session replacement and
    # events still dispatch — `patterns` must keep saying so rather than dropping
    # the pattern the moment a re-subscribe is merely in flight.
    assert_includes manager.patterns, target

    # The wait can only time out: its ack is stuck behind the parked handler.
    assert_kind_of Redis::SubscriptionError, replacer.value
    # The rollback restored the previous registration. The confirmation was never
    # deleted, so the still-subscribed, still-delivering pattern does not vanish
    # from `patterns` until a late ack happens to heal it (the listener is STILL
    # parked here — pre-fix, the pattern is missing at this point).
    assert_includes manager.patterns, target

    release << true
    r.set("kept", "v")

    assert_equal "kept", assert_pop(received).key
  ensure
    release&.push(true)
  end

  def test_attributed_rejection_marks_replaced_registrations_dead_for_rollbacks
    trigger = CHANNELS.keyspace("trigger", db: DB)
    forbidden = CHANNELS.keyspace("forbidden", db: DB)
    r.acl("SETUSER", "kn_limited4", "on", ">knpass", "+@all", "resetchannels", "&#{trigger}")
    restricted = Redis.new(OPTIONS.merge(username: "kn_limited4", password: "knpass",
                                         driver: ENV["DRIVER"], protocol: PROTOCOL))
    manager = Redis::KeyspaceNotifications::Manager.new(redis: restricted, error_handler: ->(_error) {})
    @managers << manager
    fired = Queue.new
    release = Queue.new
    manager.subscribe(trigger, handler: lambda { |_notification|
      next unless fired.empty?

      # An in-handler subscribe of a forbidden pattern, then park: the server's
      # rejection is read only after the blocking call below replaced the entry.
      manager.subscribe(forbidden, handler: ->(_n) {})
      fired << true
      release.pop
    })
    r.set("trigger", "v")
    fired.pop # the rejected registration is installed; its error is unread

    replacer = Thread.new do
      manager.subscribe(forbidden, handler: ->(_n) {})
      :subscribed
    rescue StandardError => error
      error
    end
    sleep 0.2 # the replacement is installed, remembering the rejected entry as "previous"
    release << true # the listener reads the rejection: attribution drops the in-handler batch

    # The blocking call shares the session error and rolls back. Attribution must
    # have marked the rejected (already-replaced) entry dead, or the rollback
    # restores it as "the previous registration" and every replay is poisoned.
    assert_kind_of Redis::CommandError, replacer.value
    wait_until(timeout: 5) { !manager.registered_patterns.include?(forbidden) }
    assert_equal [trigger], manager.registered_patterns
  ensure
    release&.push(true)
    begin
      r.acl("DELUSER", "kn_limited4")
    rescue StandardError
      nil
    end
  end

  private

  def new_manager(**options)
    manager = r.keyspace_notifications(**options)
    @managers << manager
    manager
  end

  def assert_pop(queue, timeout: 2)
    value = queue.pop(timeout: timeout)
    flunk "timed out waiting for a queue item" if value.nil?
    value
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield

      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end
end
