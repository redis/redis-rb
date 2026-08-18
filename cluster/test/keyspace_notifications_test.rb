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

    # The new owner emits the event while it holds the slot (the helper migrates
    # the slot back afterwards); all-primaries fan-out means we are already
    # subscribed there.
    new_owner_check = lambda do
      redis.set(key, 'v2')

      assert_equal key, queue.pop(timeout: 5)
    end

    redis_cluster_resharding(slot, src: src_key, dest: dest_key, after_finish: new_owner_check) do
      redis.set(key, 'v')

      assert_equal key, queue.pop(timeout: 5)
    end

    # And delivery still works once the slot returned to its canonical owner.
    redis.set(key, 'v3')

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

  def test_unsubscribe_with_empty_registry_is_a_noop
    queue = Queue.new
    manager = new_manager
    manager.unsubscribe # nothing registered: must not fan out "unsubscribe everything"

    manager.subscribe_keyevent('set') { |notification| queue << notification.key }
    redis.set('noop:key', 'v')

    assert_equal 'noop:key', queue.pop(timeout: 3)
  end

  def test_close_returns_promptly_under_full_queue_backpressure
    started_handling = Queue.new
    manager = new_manager(queue_size: 1)
    manager.subscribe_keyevent('set') do |_notification|
      started_handling << true
      sleep 5 # stall the dispatcher: the queue fills and node readers block in push
    end

    KEY_COUNT.times { |i| redis.set("backpressure:key#{i}", 'v') }
    started_handling.pop(timeout: 3)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    manager.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate manager, :closed?
    # Closing the queue first unblocks readers stuck in push; without it, close
    # waits out bounded joins per listener against threads stuck in Ruby, not I/O.
    assert_operator elapsed, :<, 5, 'close blocked behind readers stuck on the full queue'
  end

  def test_subscribe_recovers_listeners_after_a_fully_failed_refresh
    queue = Queue.new
    manager = new_manager
    # Simulate the aftermath of a refresh that failed for every primary: no
    # listeners, no connections, therefore no error signal to drive recovery.
    manager.instance_variable_get(:@lock).synchronize do
      manager.instance_variable_get(:@listeners).each_value(&:close)
      manager.instance_variable_get(:@listeners).clear
    end

    manager.subscribe_keyevent('set') { |notification| queue << notification.key }

    # The subscribe itself had nobody to fan out to; the refresher must rebuild.
    wait_until { manager.node_keys.size == 3 }
    redis.set('recovered:key', 'v')

    assert_equal 'recovered:key', queue.pop(timeout: 3)
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

  def test_server_rejected_pattern_is_evicted_and_raises
    allowed = '__keyevent@0__:set'
    with_channel_restricted_user([allowed]) do |username, password|
      restricted = build_another_client(username: username, password: password)
      begin
        errors = Queue.new
        manager = restricted.keyspace_notifications(error_handler: ->(error, _node) { errors << error })
        @managers << manager
        queue = Queue.new
        manager.subscribe(allowed) { |notification| queue << notification.key }
        listeners_before = manager.node_keys.sort

        error = assert_raises(Redis::CommandError) { manager.subscribe_keyevent('expired') }
        assert_match(/NOPERM|permission/i, error.message)

        # The rejected pattern was evicted (it could never succeed) and no listener
        # was torn down for what is not a node failure; the registry keeps only the
        # valid pattern, so a refresh converges instead of looping over the poison.
        assert_equal [allowed], manager.patterns
        assert_equal listeners_before, manager.node_keys.sort
        manager.refresh

        # The rejection bounced the node sessions; delivery of the valid pattern
        # recovers, but events published into the reconnect gap are lost
        # (fire-and-forget) — probe with retries.
        received = nil
        wait_until(timeout: 5) do
          redis.set('acl:probe', 'v')
          received = queue.pop(timeout: 0.5)
          !received.nil?
        end

        assert_equal 'acl:probe', received
      ensure
        manager&.close
        restricted.close
      end
    end
  end

  def test_concealed_same_port_primaries_are_rejected_under_fixed_hostname
    client = build_another_client(fixed_hostname: DEFAULT_HOST)
    # Two DISTINCT primaries (different node ids) concealing their IPs while
    # sharing a port: fixed_hostname supplies a dial target, but it cannot
    # distinguish them — one sidecar would silently miss the other's events.
    concealed = [
      { 'start_slot' => 0, 'end_slot' => 8191, 'replicas' => [],
        'master' => { 'ip' => '', 'port' => 6379, 'node_id' => 'node-a' } },
      { 'start_slot' => 8192, 'end_slot' => 16_383, 'replicas' => [],
        'master' => { 'ip' => '', 'port' => 6379, 'node_id' => 'node-b' } }
    ]
    client.stubs(:cluster).with('slots').returns(concealed)
    begin
      error = assert_raises(Redis::Cluster::KeyspaceNotificationsRefreshError) do
        client.keyspace_notifications(error_handler: ->(_error, _node) {})
      end

      assert_match(/distinguishable endpoints/, error.message)
    ensure
      client.unstub(:cluster)
      client.close
    end
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

  # A user with full command access but restricted pub/sub channels, created on
  # EVERY node (ACL is not propagated across the cluster): the manager's sidecars
  # authenticate with the cluster client's credentials on whichever primary they
  # dial, so the restriction must hold everywhere.
  def with_channel_restricted_user(allowed_channels)
    admins = DEFAULT_PORTS.map { |port| Redis.new(host: DEFAULT_HOST, port: port, timeout: TIMEOUT) }
    admins.each do |admin|
      admin.acl('SETUSER', 'kn_limited', 'on', '>knpass', '+@all',
                'resetchannels', *allowed_channels.map { |channel| "&#{channel}" })
    end
    yield('kn_limited', 'knpass')
  ensure
    admins&.each do |admin|
      begin
        admin.acl('DELUSER', 'kn_limited')
      rescue StandardError
        nil
      end
      admin.close
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield

      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
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
