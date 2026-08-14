# frozen_string_literal: true

require_relative 'helper'

# Keyspace notifications in cluster are node-local: these tests prove the manager's
# all-primaries fan-out (a single-node subscription would receive ~1/N of the events),
# its reactive refresh, and the serialized dispatch contract.
class TestClusterKeyspaceNotifications < Minitest::Test
  include Helper::Cluster

  KEY_COUNT = 30 # spread across slots so every primary owns some

  def setup
    super
    @managers = []
    # notify-keyspace-events must be set on EVERY node, replicas included: CONFIG SET
    # through the cluster client only reaches the connected primaries (replica: false),
    # and a replica promoted by a failover would otherwise emit no notifications.
    @original_flags = apply_flags_on_all_nodes('KEA')
  end

  def teardown
    @managers.each do |manager|
      manager.close
    rescue StandardError
      nil
    end
    @original_flags&.each { |port, flags| apply_node_flags(port, flags || '') }
    super
  end

  def test_receives_events_from_all_primaries
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }

    keys = Array.new(KEY_COUNT) { |i| "fanout:key#{i}" }
    keys.each { |key| redis.set(key, 'v') }

    received = collect(queue, KEY_COUNT)
    assert_equal keys.sort, received.sort
  end

  def test_pattern_subscription_across_primaries
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyspace('fan:*') { |notification| queue << notification }

    redis.set('fan:a', 'v')
    redis.del('fan:a')

    notifications = collect(queue, 2)
    assert_equal %w[del set], notifications.map(&:event).sort
    notifications.each do |notification|
      assert_equal :keyspace, notification.family
      assert_equal 0, notification.db
      assert_equal 'fan:a', notification.key
    end
  end

  def test_unsubscribe_stops_delivery_and_survives_refresh
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }
    manager.unsubscribe

    manager.refresh
    KEY_COUNT.times { |i| redis.set("silent:key#{i}", 'v') }
    sleep 0.3

    assert_predicate queue, :empty?
    assert_empty manager.patterns
  end

  def test_handler_dispatch_is_serialized
    entered = false
    overlaps = 0
    done = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') do |_notification|
      overlaps += 1 if entered
      entered = true
      sleep 0.001
      entered = false
      done << true
    end

    KEY_COUNT.times { |i| redis.set("serial:key#{i}", 'v') }
    collect(done, KEY_COUNT)

    assert_equal 0, overlaps
  end

  def test_node_keys_match_primaries
    manager = new_manager
    masters = redis.cluster('slots').map { |r| "#{r['master']['ip']}:#{r['master']['port']}" }.uniq

    assert_equal masters.sort, manager.node_keys.sort
  end

  def test_close_is_idempotent_and_stops_delivery
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }
    manager.close
    manager.close

    assert_predicate manager, :closed?
    redis.set('closed:key', 'v')
    sleep 0.2

    assert_predicate queue, :empty?
    assert_raises(Redis::SubscriptionError) { manager.subscribe('__keyevent@0__:set') }
  end

  def test_reactive_refresh_after_connection_kill
    queue = Queue.new
    errors = Queue.new
    manager = new_manager(error_handler: ->(error, _node_key) { errors << error })
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }

    # Kill every pub/sub connection on one primary: its listener errors, reports,
    # and the manager reconciles reactively.
    victim = manager.node_keys.first
    host, port = victim.split(':')
    node = Redis.new(host: host, port: Integer(port), timeout: TIMEOUT)
    begin
      node.client(:kill, 'TYPE', 'pubsub')
    ensure
      node.close
    end

    refute_nil errors.pop(timeout: 5), 'expected the killed connection to be reported'

    keys = Array.new(KEY_COUNT) { |i| "revive:key#{i}" }
    received = nil
    10.times do
      queue.clear
      keys.each { |key| redis.set(key, 'v') }
      received = collect(queue, KEY_COUNT, timeout: 2, flunk_on_timeout: false)
      break if received.size == KEY_COUNT

      sleep 0.5
    end

    assert_equal keys.sort, received.sort, 'expected full delivery to resume after the kill'
  end

  def test_events_keep_flowing_across_resharding
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }

    key = 'reshard:key'
    slot = ::RedisClient::Cluster::KeySlotConverter.convert(key)
    slots = redis.cluster('slots')
    src = slots.find { |r| (r['start_slot']..r['end_slot']).cover?(slot) }
    dest = slots.find { |r| !(r['start_slot']..r['end_slot']).cover?(slot) }
    src_key = "#{src['master']['ip']}:#{src['master']['port']}"
    dest_key = "#{dest['master']['ip']}:#{dest['master']['port']}"

    redis_cluster_resharding(slot, src: src_key, dest: dest_key) do
      redis.set(key, 'v')
      assert_equal key, queue.pop(timeout: 5)
    end

    # After the migration the new owner emits the event; all-primaries fan-out
    # means we are already subscribed there.
    redis.set(key, 'v2')
    assert_equal key, queue.pop(timeout: 5)
  end

  def test_manual_refresh_after_failover
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }

    redis_cluster_failover do
      # The long-lived test client's router can keep raising NodeMightBeDown for a
      # while after a takeover; a fresh client bootstraps the settled topology.
      writer = build_another_client
      keys = Array.new(KEY_COUNT) { |i| "failover:key#{i}" }
      received = nil
      last_error = nil
      30.times do
        begin
          manager.refresh
          queue.clear
          keys.each { |key| writer.set(key, 'v') }
        rescue Redis::Cluster::NodeMightBeDown, Redis::BaseConnectionError,
               Redis::Cluster::KeyspaceNotificationsRefreshError, Redis::CommandError => error
          last_error = error
          sleep 0.5
          next
        end

        received = collect(queue, KEY_COUNT, timeout: 2, flunk_on_timeout: false)
        break if received.size == KEY_COUNT

        sleep 0.5
      end

      assert_equal keys.sort, received&.sort,
                   "expected full delivery after failover + refresh (last error: #{last_error.inspect})"
    ensure
      writer&.close
    end
  end

  def test_refresh_with_empty_slots_reply_keeps_listeners_and_raises
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }
    listeners_before = manager.node_keys.sort

    # A degraded/mid-reset node can answer CLUSTER SLOTS with an empty reply; the
    # manager must refuse to reconcile against it rather than tear everything down.
    redis.stubs(:cluster).with('slots').returns([])
    begin
      assert_raises(Redis::Cluster::KeyspaceNotificationsRefreshError) { manager.refresh }
    ensure
      redis.unstub(:cluster)
    end

    assert_equal listeners_before, manager.node_keys.sort
    redis.set('survivor:key', 'v')

    assert_equal 'survivor:key', queue.pop(timeout: 3)
  end

  def test_subkey_notifications_on_cluster
    omit_version('8.8.0')

    apply_flags_on_all_nodes('KEASTIV')
    queue = Queue.new
    manager = new_manager
    manager.subscribe_subkeyevent('hdel') { |notification| queue << notification }

    redis.hset('subkey:hash', 'name', 'alice', 'email', 'a@example.com')
    redis.hdel('subkey:hash', 'name', 'email')

    notification = queue.pop(timeout: 3)
    refute_nil notification, 'expected a subkeyevent notification'
    assert_equal :subkeyevent, notification.family
    assert_equal 'hdel', notification.event
    assert_equal 'subkey:hash', notification.key
    assert_equal %w[name email], notification.subkeys
  end

  private

  def new_manager(**options)
    manager = redis.keyspace_notifications(**options)
    @managers << manager
    manager
  end

  def apply_flags_on_all_nodes(flags)
    DEFAULT_PORTS.to_h do |port|
      node = Redis.new(host: DEFAULT_HOST, port: port, timeout: TIMEOUT)
      begin
        original = node.config(:get, 'notify-keyspace-events')['notify-keyspace-events']
        node.config(:set, 'notify-keyspace-events', flags)
        [port, original]
      ensure
        node.close
      end
    end
  end

  def apply_node_flags(port, flags)
    node = Redis.new(host: DEFAULT_HOST, port: port, timeout: TIMEOUT)
    node.config(:set, 'notify-keyspace-events', flags)
    node.close
  rescue StandardError
    nil
  end

  def collect(queue, count, timeout: 3, flunk_on_timeout: true)
    items = []
    count.times do
      item = queue.pop(timeout: timeout)
      if item.nil?
        flunk "timed out after #{items.size}/#{count} items" if flunk_on_timeout
        break
      end
      items << item
    end
    items
  end
end
