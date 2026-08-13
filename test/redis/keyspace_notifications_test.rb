# frozen_string_literal: true

require "helper"

# End-to-end wire-format coverage against real server-emitted notifications:
# `notify-keyspace-events` is enabled at runtime and restored afterwards. Subkey
# families need Redis 8.8+ and are version-gated. The manager's dispatch/lifecycle
# mechanics are covered in test/redis/keyspace_notifications/manager_test.rb (also
# against real server-emitted events).
class TestKeyspaceNotifications < Minitest::Test
  include Helper::Client

  def setup
    super
    @original_flags = r.config(:get, "notify-keyspace-events")["notify-keyspace-events"]
    @managers = []
  end

  def teardown
    @managers.each do |manager|
      manager.close
    rescue StandardError
      nil
    end
    r.config(:set, "notify-keyspace-events", @original_flags) if @original_flags
    super
  end

  def test_receives_keyspace_event_for_set
    apply_flags "KEA"
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyspace("e2e:*", db: 15) { |notification| queue << notification }

    r.set("e2e:key", "value")

    notification = assert_pop(queue)
    assert_equal :keyspace, notification.family
    assert_equal 15, notification.db
    assert_equal "set", notification.event
    assert_equal "e2e:key", notification.key
    assert_empty notification.subkeys
  end

  def test_receives_expired_event_via_keyevent
    apply_flags "KEA"
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent("expired", db: 15) { |notification| queue << notification }

    r.set("e2e:short-lived", "value", px: 50)

    notification = assert_pop(queue, timeout: 5)
    assert_equal :keyevent, notification.family
    assert_equal "expired", notification.event
    assert_equal "e2e:short-lived", notification.key
  end

  def test_dsl_layer_psubscribe_with_parser
    apply_flags "KEA"
    queue = Queue.new
    subscriber = Redis.new(OPTIONS)
    pattern = Redis::KeyspaceNotifications::Channels.keyspace("dsl:*", db: 15)

    thread = Thread.new do
      subscriber.psubscribe(pattern) do |on|
        on.psubscribe { |_pattern, _count| queue << :ready }
        on.pmessage do |matched, channel, payload|
          queue << Redis::KeyspaceNotifications::Parser.parse(channel, payload, pattern: matched)
          subscriber.punsubscribe
        end
      end
    end
    thread.report_on_exception = true

    assert_equal :ready, assert_pop(queue)
    r.set("dsl:key", "value")

    notification = assert_pop(queue)
    assert_equal "set", notification.event
    assert_equal "dsl:key", notification.key
    assert_equal pattern, notification.pattern
    assert thread.join(2), "subscriber thread leaked"
  ensure
    subscriber&.close
  end

  def test_receives_subkeyspace_for_hset_fields
    target_version("8.8") do
      apply_flags "KEASTIV"
      queue = Queue.new
      manager = new_manager
      manager.subscribe_subkeyspace("e2e:hash", db: 15) { |notification| queue << notification }

      r.hset("e2e:hash", "name", "alice", "email", "a@example.com")

      notification = assert_pop(queue)
      assert_equal :subkeyspace, notification.family
      assert_equal "hset", notification.event
      assert_equal "e2e:hash", notification.key
      assert_equal %w[name email], notification.subkeys
    end
  end

  def test_receives_subkeyevent_for_hdel
    target_version("8.8") do
      apply_flags "KEASTIV"
      queue = Queue.new
      manager = new_manager
      manager.subscribe_subkeyevent("hdel", db: 15) { |notification| queue << notification }

      r.hset("e2e:hash", "name", "alice", "email", "a@example.com")
      r.hdel("e2e:hash", "name", "email")

      notification = assert_pop(queue)
      assert_equal :subkeyevent, notification.family
      assert_equal "hdel", notification.event
      assert_equal "e2e:hash", notification.key
      assert_equal %w[name email], notification.subkeys
    end
  end

  def test_receives_subkeyspaceitem_for_single_field
    target_version("8.8") do
      apply_flags "KEASTIV"
      queue = Queue.new
      manager = new_manager
      manager.subscribe_subkeyspaceitem("e2e:hash", "name", db: 15) { |notification| queue << notification }

      r.hset("e2e:hash", "name", "alice", "email", "a@example.com")

      notification = assert_pop(queue)
      assert_equal :subkeyspaceitem, notification.family
      assert_equal "hset", notification.event
      assert_equal "e2e:hash", notification.key
      assert_equal "name", notification.subkey

      # The email field's notification goes to a different channel: nothing else queued.
      sleep 0.1
      assert_predicate queue, :empty?
    end
  end

  def test_receives_subkeyspaceevent_with_key_pattern
    target_version("8.8") do
      apply_flags "KEASTIV"
      queue = Queue.new
      manager = new_manager
      manager.subscribe_subkeyspaceevent("hset", "e2e:*", db: 15) { |notification| queue << notification }

      r.hset("e2e:hash", "name", "alice")

      notification = assert_pop(queue)
      assert_equal :subkeyspaceevent, notification.family
      assert_equal "hset", notification.event
      assert_equal "e2e:hash", notification.key
      assert_equal %w[name], notification.subkeys
    end
  end

  def test_hash_field_expiration_emits_subkeys
    target_version("8.8") do
      apply_flags "KEASTIV"
      queue = Queue.new
      manager = new_manager
      manager.subscribe_subkeyevent("hexpire", db: 15) { |notification| queue << notification }

      r.hset("e2e:hash", "email", "a@example.com")
      r.hexpire("e2e:hash", 100, "FIELDS", 1, "email")

      notification = assert_pop(queue)
      assert_equal "hexpire", notification.event
      assert_equal %w[email], notification.subkeys
    end
  end

  def test_subkey_flags_require_the_type_flag
    target_version("8.8") do
      apply_flags "STIV" # no `h`/`A` type flag: hash subkey events must NOT fire
      queue = Queue.new
      manager = new_manager
      manager.subscribe_subkeyspace("e2e:hash", db: 15) { |notification| queue << notification }

      r.hset("e2e:hash", "name", "alice")

      sleep 0.1
      assert_predicate queue, :empty?
    end
  end

  private

  def apply_flags(flags)
    r.config(:set, "notify-keyspace-events", flags)
  end

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
end
