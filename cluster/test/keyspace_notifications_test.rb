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
        # Break only on EXACT delivery — every key once, no duplicates. A manual
        # failover demotes the old primary without dropping its connections, and
        # as a replica it re-emits every replicated write; a refresh that sampled
        # a node with a stale gossip view (old primary still reported as master)
        # keeps it listened, so its shard's events arrive TWICE. Counting items
        # alone would accept such a duplicated batch. Retrying rides out the
        # gossip window: a later refresh sees the settled view, prunes the
        # demoted node, and delivery converges to exactly-once.
        break if received.sort == keys.sort

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
      # Stall the dispatcher for longer than the whole close sequence: the queue
      # fills and node readers block in push, and nothing but close's
      # queue-close can ever free them (a shorter stall would end around when
      # close returns, drain the queue itself, and mask a missing queue-close).
      sleep 60
    end

    KEY_COUNT.times { |i| redis.set("backpressure:key#{i}", 'v') }
    started_handling.pop(timeout: 3)

    # The regression signal is BEHAVIORAL, not a tight wall-clock bound: closing
    # the queue first unblocks readers stuck in push, so every node listener
    # thread terminates within close's bounded joins. Without it the readers
    # stay stuck in Ruby (not I/O — force-closing their sockets can't help),
    # close burns the same bounded joins, and the threads leak alive. Capture
    # them before close prunes the listener registry.
    reader_threads = manager.instance_variable_get(:@lock).synchronize do
      manager.instance_variable_get(:@listeners).values.map do |listener|
        listener.instance_variable_get(:@manager).instance_variable_get(:@thread)
      end
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    manager.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate manager, :closed?
    reader_threads.each do |thread|
      refute_predicate thread, :alive?, 'a node reader stayed stuck on the full queue through close'
    end
    # Loose sanity bound only — close's legitimate worst case is a stack of
    # bounded joins (parallel per-listener join + force-close join, the
    # refresher's and the stalled dispatcher's join timeouts ≈ 8s), which a
    # tight threshold would race on a loaded machine.
    assert_operator elapsed, :<, 10, 'close exceeded even its bounded-join worst case'
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

  def test_refresh_with_no_slot_owning_primaries_keeps_listeners_and_raises
    queue = Queue.new
    manager = new_manager
    manager.subscribe_keyevent('set') { |notification| queue << notification.key }
    listeners_before = manager.node_keys.sort

    # A degraded/mid-reset node can answer CLUSTER NODES with a view containing
    # no slot-owning primary (e.g. only itself, freshly reset); the manager must
    # refuse to reconcile against it rather than tear everything down.
    degraded = [
      { 'node_id' => 'reset-node', 'ip_port' => '127.0.0.1:7000@17000',
        'flags' => %w[myself master], 'master_node_id' => '-', 'ping_sent' => '0',
        'pong_recv' => '0', 'config_epoch' => '0', 'link_state' => 'connected', 'slots' => nil }
    ]
    redis.stubs(:cluster).with('nodes').returns(degraded)
    begin
      assert_raises(Redis::Cluster::KeyspaceNotificationsRefreshError) { manager.refresh }
    ensure
      redis.unstub(:cluster)
    end

    assert_equal listeners_before, manager.node_keys.sort
    redis.set('survivor:key', 'v')

    assert_equal 'survivor:key', queue.pop(timeout: 3)
  end

  def test_primary_enumeration_includes_zero_slot_masters
    manager = new_manager
    # A scale-out primary owns no slots yet: CLUSTER SLOTS could never show it,
    # and a listener attached only after resharding would silently miss every
    # notification for the migrated keys until some unrelated refresh. The
    # membership view must include it — and must still exclude replicas,
    # confirmed-failed masters and handshaking nodes.
    view = [
      { 'node_id' => 'a', 'ip_port' => '127.0.0.1:7000@17000', 'flags' => %w[master],
        'master_node_id' => '-', 'link_state' => 'connected', 'slots' => Range.new('0', '16383') },
      { 'node_id' => 'b', 'ip_port' => '127.0.0.1:7006@17006', 'flags' => %w[master],
        'master_node_id' => '-', 'link_state' => 'connected', 'slots' => nil },
      { 'node_id' => 'c', 'ip_port' => '127.0.0.1:7003@17003', 'flags' => %w[slave],
        'master_node_id' => 'a', 'link_state' => 'connected', 'slots' => nil },
      { 'node_id' => 'd', 'ip_port' => '127.0.0.1:7009@17009', 'flags' => %w[master fail],
        'master_node_id' => '-', 'link_state' => 'disconnected', 'slots' => nil },
      { 'node_id' => 'e', 'ip_port' => '127.0.0.1:7012@17012', 'flags' => %w[handshake master],
        'master_node_id' => '-', 'link_state' => 'connected', 'slots' => nil }
    ]
    redis.stubs(:cluster).with('nodes').returns(view)
    begin
      primaries = manager.send(:current_primaries)

      assert_equal ['127.0.0.1:7000', '127.0.0.1:7006'], primaries.keys.sort
      assert_equal ['127.0.0.1', '7006'], primaries['127.0.0.1:7006']
    ensure
      redis.unstub(:cluster)
    end
  end

  def test_mid_failover_view_is_rejected_and_keeps_listeners
    manager = new_manager
    # Mid-failover: the dying primary carries the `fail` flag but still owns its
    # slots (its replica has not claimed them yet). Reconciling against this view
    # would succeed with N-1 listeners and stop the reactive refresher — the
    # promoted primary would then be silently missed until an unrelated refresh.
    view = [
      { 'node_id' => 'a', 'ip_port' => '127.0.0.1:7000@17000', 'flags' => %w[master],
        'master_node_id' => '-', 'link_state' => 'connected', 'slots' => Range.new('0', '8191') },
      { 'node_id' => 'b', 'ip_port' => '127.0.0.1:7001@17001', 'flags' => %w[master fail],
        'master_node_id' => '-', 'link_state' => 'disconnected', 'slots' => Range.new('8192', '16383') },
      { 'node_id' => 'c', 'ip_port' => '127.0.0.1:7003@17003', 'flags' => %w[slave],
        'master_node_id' => 'b', 'link_state' => 'connected', 'slots' => nil }
    ]
    redis.stubs(:cluster).with('nodes').returns(view)
    begin
      error = assert_raises(Redis::Cluster::KeyspaceNotificationsRefreshError) do
        manager.send(:current_primaries)
      end

      assert_match(/failover in progress/, error.message)
    ensure
      redis.unstub(:cluster)
    end
  end

  def test_cluster_nodes_reshaping_tolerates_single_slot_and_marker_fields
    hashify = Redis::Commands::HashifyClusterNodeInfo
    prefix = 'abc 127.0.0.1:7006@17006 master - 0 0 7 connected'
    # A lone slot number is a valid CLUSTER NODES form (e.g. a scale-out
    # primary's first migrated slot); it used to crash Range.new and take the
    # whole refresh enumeration down with it.
    assert_equal Range.new('5460', '5460'), hashify.call("#{prefix} 5460")['slots']
    assert_equal Range.new('0', '5460'), hashify.call("#{prefix} 0-5460")['slots']
    # A bracketed importing/migrating marker is not an owned slot.
    assert_nil hashify.call("#{prefix} [5460-<-def]")['slots']
    assert_nil hashify.call(prefix)['slots']
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

        # The rejected pattern was evicted (it could never succeed), leaving only
        # the valid pattern registered. The rejection bounced every node's
        # subscriber session, so the concurrent reactive refresh may transiently
        # prune and rebuild listeners whose core managers are mid-reconnect —
        # node_keys is only stable again after a refresh converges. A refresh over
        # the cleaned registry must succeed (the poison would have failed it on
        # every primary and destroyed the listeners in a loop) and restore the
        # full listener set.
        assert_equal [allowed], manager.patterns
        manager.refresh

        assert_equal listeners_before, manager.node_keys.sort

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

  def test_background_replay_rejection_reconciles_the_registry
    allowed = '__keyevent@0__:set'
    poisoned = '__keyevent@0__:expired'
    with_channel_restricted_user([allowed, poisoned]) do |username, password, reconfigure|
      restricted = build_another_client(username: username, password: password)
      begin
        errors = Queue.new
        manager = restricted.keyspace_notifications(error_handler: ->(error, _node) { errors << error })
        @managers << manager
        queue = Queue.new
        manager.subscribe(allowed) { |notification| queue << notification.key }
        manager.subscribe(poisoned) { |_notification| }

        # Revoke the second pattern AFTER it was subscribed: the server kills the
        # user's pub/sub sessions, every node's reconnect replay is rejected, and
        # each node's core manager evicts the pattern from its LOCAL registry.
        # The CommandError must schedule a refresh whose catch-up re-runs the
        # rejection and evicts it from the canonical registry too — without it,
        # `patterns` kept reporting a pattern no node was subscribed to, with no
        # signal left to ever converge.
        reconfigure.call([allowed])

        wait_until(timeout: 10) { !manager.patterns.include?(poisoned) }

        # The surviving pattern recovers once the reconciled topology settles
        # (events published into the bounce are lost — probe with retries).
        received = nil
        wait_until(timeout: 10) do
          redis.set('acl:background', 'v')
          received = queue.pop(timeout: 0.5)
          !received.nil?
        end

        assert_equal 'acl:background', received
        assert_equal [allowed], manager.patterns
      ensure
        manager&.close
        restricted.close
      end
    end
  end

  def test_close_from_rejection_error_handler_during_refresh
    allowed = '__keyevent@0__:set'
    with_channel_restricted_user([allowed]) do |username, password|
      restricted = build_another_client(username: username, password: password)
      begin
        manager = nil
        forbidden = '__keyevent@0__:expired'
        closed_from_handler = Queue.new
        error_handler = lambda do |error, _node_key|
          next unless error.is_a?(Redis::CommandError)
          # The node readers report the same rejection too (mostly while the
          # pattern is still registered, but a delayed one can slip past the
          # registry filter). Only the refresher's own deferred report is under
          # test: it must arrive with the refresh lock RELEASED — under the lock
          # (the pre-fix behavior) close raises ThreadError, is swallowed, and the
          # manager keeps running. Probe the lock non-blockingly: a reader-thread
          # report racing the in-flight refresh legitimately sees it held and must
          # not close from there (that would park the reader the refresh needs and
          # stall the test on ack timeouts — the documented reason error handlers
          # should not call close synchronously).
          next if manager.nil? || manager.patterns.include?(forbidden)

          refresh_lock = manager.instance_variable_get(:@refresh_lock)
          next unless refresh_lock.try_lock

          refresh_lock.unlock
          manager.close
          closed_from_handler << true
        end
        manager = restricted.keyspace_notifications(error_handler: error_handler)
        @managers << manager
        subscribed_once = Queue.new
        manager.subscribe(allowed) do |_notification|
          # An in-handler subscribe of a forbidden pattern: deferred to the
          # refresher, whose catch-up hits the rejection and evicts it.
          manager.subscribe(forbidden) { |_n| } if subscribed_once.empty?
          subscribed_once << true
        end
        redis.set('reject:trigger', 'v')

        assert closed_from_handler.pop(timeout: 15),
               'the post-eviction rejection report never reached the error handler'
        wait_until { manager.closed? }
      ensure
        restricted.close
      end
    end
  end

  def test_subscribe_reports_every_nodes_error_after_a_rejection
    errors = Queue.new
    manager = new_manager(error_handler: ->(error, node_key) { errors << [error, node_key] })
    listeners = manager.instance_variable_get(:@lock).synchronize do
      manager.instance_variable_get(:@listeners).dup
    end
    rejection = Redis::CommandError.new('NOPERM this user has no permissions to access one of the channels')
    failure = Redis::ConnectionError.new('node went away mid fan-out')
    keys = listeners.keys
    listeners[keys.first].stubs(:subscribe).raises(rejection)
    keys[1..].each { |key| listeners[key].stubs(:subscribe).raises(failure) }
    pattern = '__keyevent@0__:expired'

    assert_raises(Redis::CommandError) { manager.subscribe(pattern) { |_n| } }

    # The rejection is raised to the caller; every node that failed for a
    # DIFFERENT reason must still be reported with its node_key, never silently
    # dropped behind the raise.
    expected = keys[1..]
    reported = Array.new(expected.size) { errors.pop(timeout: 1) }
    refute_includes reported, nil, 'expected one report per additional failed node'
    assert_equal expected.sort, reported.map(&:last).sort
    reported.each { |report| assert_same failure, report.first }
    refute_includes manager.patterns, pattern
  end

  def test_subscribe_evicts_only_the_rejected_pattern_of_a_multi_pattern_call
    manager = new_manager(error_handler: ->(_error, _node_key) {})
    listeners = manager.instance_variable_get(:@lock).synchronize do
      manager.instance_variable_get(:@listeners).dup
    end
    rejection = Redis::CommandError.new('NOPERM channel')
    allowed = '__keyevent@0__:set'
    forbidden = '__keyevent@0__:expired'
    # The fan-out subscribes one pattern per call, so a rejection names exactly
    # its pattern: the call's other patterns must stay registered and fanned out.
    listeners.each_value do |listener|
      listener.stubs(:subscribe).returns(nil)
      listener.stubs(:subscribe).with([allowed.b]).returns(nil)
      listener.stubs(:subscribe).with([forbidden.b]).raises(rejection)
    end

    error = assert_raises(Redis::CommandError) { manager.subscribe(allowed, forbidden) { |_n| } }

    assert_same rejection, error
    assert_includes manager.patterns, allowed
    refute_includes manager.patterns, forbidden
  end

  def test_close_aborts_an_inflight_refresh_promptly
    manager = new_manager
    manager.subscribe_keyevent('set') { |_n| }
    entered = Queue.new
    manager.instance_variable_get(:@lock).synchronize do
      manager.instance_variable_get(:@listeners).each_value do |listener|
        listener.define_singleton_method(:catch_up) do |_patterns|
          entered << true
          sleep 1.5
          self
        end
      end
    end

    refresher = Thread.new do
      manager.refresh
    rescue StandardError
      nil
    end
    refute_nil entered.pop(timeout: 3), 'the refresh never reached its first catch-up'

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    manager.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate manager, :closed?
    # close raises @closed before waiting on the refresh lock, and the in-flight
    # refresh aborts at the next node boundary: aborted, close waits out at most
    # the CURRENT catch-up (~1.5s) plus teardown; without the abort it would sit
    # out every remaining catch-up too (>= 4.5s of stubbed sleeps) with close
    # blocked behind the lock. The threshold sits between, with headroom for a
    # loaded machine's slower teardown joins.
    assert_operator elapsed, :<, 4, 'close waited out the whole in-flight refresh'
    refresher.join(5)
  end

  def test_on_reconnect_announces_a_recovered_node
    reconnects = Queue.new
    manager = new_manager(error_handler: ->(_error, _node_key) {}) # the kill below is expected noise
    manager.on_reconnect { |node_key| reconnects << node_key }
    manager.subscribe_keyevent('set') { |_n| }

    # Kill the pub/sub connection on one primary: whichever path re-establishes
    # its subscriptions — the listener's own reconnect replay, or the reactive
    # refresh rebuilding it — must announce the gap's end with the node_key.
    victim = manager.node_keys.first
    host, port = victim.split(':')
    node = Redis.new(host: host, port: Integer(port), timeout: TIMEOUT)
    begin
      node.client(:kill, 'TYPE', 'pubsub')
    ensure
      node.close
    end

    announced = nil
    10.times do
      announced = reconnects.pop(timeout: 2)
      break if announced == victim
    end

    assert_equal victim, announced, 'expected the recovered node to be announced to on_reconnect'
  end

  def test_on_reconnect_announces_a_newly_attached_listener_after_refresh
    reconnects = Queue.new
    manager = new_manager(error_handler: ->(_error, _node_key) {})
    manager.on_reconnect { |node_key| reconnects << node_key }
    manager.subscribe_keyevent('set') { |_n| }

    # Tear one node's listener down silently (no error signal), as if a previous
    # refresh had failed on it: the next refresh attaches a fresh listener and
    # must announce the node once it converged. Announcements key on ATTACHMENT,
    # so the same path covers a promoted replica replacing a dead primary under
    # a new node_key and a scale-out primary — gaps a mark under the vanished
    # node's key could never announce.
    victim = manager.node_keys.first
    listener = manager.instance_variable_get(:@lock).synchronize do
      manager.instance_variable_get(:@listeners).delete(victim)
    end
    listener&.close
    manager.refresh

    assert_equal victim, reconnects.pop(timeout: 2),
                 'expected the newly attached node to be announced to on_reconnect'
  end

  def test_concealed_same_port_primaries_are_rejected_under_fixed_hostname
    client = build_another_client(fixed_hostname: DEFAULT_HOST)
    # Two DISTINCT primaries (different node ids) concealing their IPs while
    # sharing a port: fixed_hostname supplies a dial target, but it cannot
    # distinguish them — one sidecar would silently miss the other's events.
    concealed = [
      { 'node_id' => 'node-a', 'ip_port' => ':6379@16379', 'flags' => %w[master],
        'master_node_id' => '-', 'link_state' => 'connected', 'slots' => Range.new('0', '8191') },
      { 'node_id' => 'node-b', 'ip_port' => ':6379@16379', 'flags' => %w[master],
        'master_node_id' => '-', 'link_state' => 'connected', 'slots' => Range.new('8192', '16383') }
    ]
    client.stubs(:cluster).with('nodes').returns(concealed)
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
    # Reapplies the channel list on every node; narrowing it mid-test also kills
    # the user's pub/sub sessions server-side (revoked-after-subscribe scenarios).
    reconfigure = lambda do |channels|
      admins.each do |admin|
        admin.acl('SETUSER', 'kn_limited', 'on', '>knpass', '+@all',
                  'resetchannels', *channels.map { |channel| "&#{channel}" })
      end
    end
    reconfigure.call(allowed_channels)
    yield('kn_limited', 'knpass', reconfigure)
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
