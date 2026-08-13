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
    r.set("k", "v")
    sleep 0.1

    assert_predicate queue, :empty?
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
