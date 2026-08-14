# frozen_string_literal: true

require 'redis'

class ClusterOrchestrator
  SLOT_SIZE = 16_384

  def initialize(node_addrs, timeout: 30.0)
    raise 'Redis Cluster requires at least 3 master nodes.' if node_addrs.size < 3

    @clients = node_addrs.map do |addr|
      Redis.new(url: addr, timeout: timeout, reconnect_attempts: [0, 0.5, 1, 1.5])
    end
    @timeout = timeout
  end

  def restart_cluster_nodes
    system('make', '--no-print-directory', 'start_cluster', out: File::NULL, err: File::NULL)
  end

  # Full teardown-and-rebuild takes ~6s of genuine gossip/replication convergence,
  # so skip it when the cluster already matches the expected layout — helpers restore
  # state cheaply after their scenario (failback, reverse resharding) precisely so
  # this fast path applies; any deviation still falls through to the full rebuild.
  # The short bounded wait tolerates sub-second gossip lag from that restore without
  # letting an actually-broken cluster delay the real rebuild by more than ~2s.
  def rebuild
    return if wait_cluster_consistent(max_attempts: 20)

    flush_all_data(@clients)
    reset_cluster(@clients)
    assign_slots(@clients)
    save_config_epoch(@clients)
    meet_each_other(@clients)
    wait_meeting(@clients)
    replicate(@clients)
    save_config(@clients)
    wait_cluster_building(@clients)
    wait_replication(@clients)
    wait_cluster_recovering(@clients)
    wait_consistent_slots_view(@clients)
  end

  def down
    flush_all_data(@clients)
    reset_cluster(@clients)
  end

  def fail_serving_master
    master, slave = take_replication_pairs(@clients)
    master.shutdown
    attempt_count = 1
    max_attempts = 500
    attempt_count.step(max_attempts) do |i|
      return if slave.role == 'master' || i >= max_attempts

      attempt_count += 1
      sleep 0.1
    end
  end

  def failover
    master, slave = take_replication_pairs(@clients)
    wait_replication_delay(@clients, @timeout)
    slave.cluster(:failover, :takeover)
    wait_failover(to_node_key(master), to_node_key(slave), @clients)
    wait_replication_delay(@clients, @timeout)
    wait_cluster_recovering(@clients)
  end

  # Reverses #failover by promoting the original master back. Takes ~1-2s versus the
  # ~6s full rebuild, letting the ensure-time rebuild skip its teardown entirely.
  #
  # Role-aware rather than assuming the pair is still switched: a manual TAKEOVER
  # bumps the config epoch unilaterally, and the ensuing collision resolution can
  # go the old master's way, silently reverting the promotion mid-test. In that
  # case there is nothing to fail back — and the rebuild's consistency check
  # remains the safety net for any state this leaves behind.
  def failback
    master, slave = take_replication_pairs(@clients)
    return if master.role.first == 'master'

    wait_replication_delay(@clients, @timeout)
    begin
      master.cluster(:failover, :takeover)
    rescue Redis::CommandError => err
      # "ERR You should send CLUSTER FAILOVER to a replica" — the node became a
      # master between the role check and the command; already failed back.
      return if err.message.include?('to a replica')

      raise
    end
    wait_failover(to_node_key(slave), to_node_key(master), @clients)
    wait_replication_delay(@clients, @timeout)
    wait_cluster_recovering(@clients)
  end

  def start_resharding(slot, src_node_key, dest_node_key, slice_size: 10)
    node_map = hashify_node_map(@clients.first)
    src_node_id = node_map.fetch(src_node_key)
    src_client = find_client(@clients, src_node_key)
    dest_node_id = node_map.fetch(dest_node_key)
    dest_client = find_client(@clients, dest_node_key)
    dest_host, dest_port = dest_node_key.split(':')

    dest_client.cluster(:setslot, slot, 'IMPORTING', src_node_id)
    src_client.cluster(:setslot, slot, 'MIGRATING', dest_node_id)

    keys_count = src_client.cluster(:countkeysinslot, slot)
    loop do
      break if keys_count <= 0

      keys = src_client.cluster(:getkeysinslot, slot, slice_size)
      break if keys.empty?

      keys.each do |k|
        src_client.migrate(k, host: dest_host, port: dest_port)
      rescue Redis::CommandError => err
        raise unless err.message.start_with?('IOERR')

        src_client.migrate(k, host: dest_host, port: dest_port, replace: true) # retry once
      ensure
        keys_count -= 1
      end
    end
  end

  def finish_resharding(slot, dest_node_key)
    node_map = hashify_node_map(@clients.first)
    node_id = node_map.fetch(dest_node_key)
    # Tell every master directly instead of relying on gossip from a single node:
    # views converge immediately, and a client positioned on a node that happens to
    # be a replica no longer breaks the flow with "SETSLOT only with masters".
    take_masters(@clients).each do |client|
      client.cluster(:setslot, slot, 'NODE', node_id)
    rescue Redis::CommandError
      nil # a node that believes it is a replica rejects SETSLOT; gossip covers it
    end
  end

  def close
    @clients.each(&:quit)
  end

  private

  def flush_all_data(clients)
    clients.each do |c|
      # Never FLUSHALL a replica: it answers READONLY, which redis-client treats as a
      # connection error and walks the whole reconnect_attempts sleep schedule for —
      # 3s per replica of pure wasted wall clock.
      c.flushall(async: true) if c.role.first == 'master'
    rescue Redis::CommandError, Redis::BaseConnectionError
      nil
    end
  end

  def reset_cluster(clients)
    clients.each { |c| c.cluster(:reset) }
  end

  def assign_slots(clients)
    masters = take_masters(clients)
    slot_slice = SLOT_SIZE / masters.size
    mod = SLOT_SIZE % masters.size
    slot_sizes = Array.new(masters.size, slot_slice)
    mod.downto(1) { |i| slot_sizes[i] += 1 }

    slot_idx = 0
    masters.zip(slot_sizes).each do |c, s|
      slot_range = slot_idx..slot_idx + s - 1
      c.cluster(:addslots, *slot_range.to_a)
      slot_idx += s
    end
  end

  def save_config_epoch(clients)
    clients.each_with_index do |c, i|
      c.cluster('set-config-epoch', i + 1)
    rescue Redis::CommandError
      # ERR Node config epoch is already non-zero
      nil
    end
  end

  def meet_each_other(clients)
    first_client = clients.first
    target_info = first_client.connection
    target_host = target_info.fetch(:host)
    target_port = target_info.fetch(:port)

    clients.each do |client|
      next if first_client.id == client.id

      client.cluster(:meet, target_host, target_port)
    end
  end

  def wait_meeting(clients, max_attempts: 60)
    size = clients.size.to_s

    wait_for_state(clients, max_attempts) do |client|
      info = hashify_cluster_info(client)
      info['cluster_known_nodes'] == size
    end
  end

  def replicate(clients)
    node_map = hashify_node_map(clients.first)
    masters = take_masters(clients)

    take_slaves(clients).each_with_index do |slave, i|
      master_info = masters[i].connection
      master_host = master_info.fetch(:host)
      master_port = master_info.fetch(:port)

      loop do
        begin
          master_node_id = node_map.fetch("#{master_host}:#{master_port}")
          slave.cluster(:replicate, master_node_id)
        rescue Redis::CommandError
          # ERR Unknown node [key]
          sleep 0.1
          node_map = hashify_node_map(clients.first)
          next
        end

        break
      end
    end
  end

  def save_config(clients)
    clients.each { |c| c.cluster(:saveconfig) }
  end

  def wait_cluster_building(clients, max_attempts: 60)
    wait_for_state(clients, max_attempts) do |client|
      info = hashify_cluster_info(client)
      info['cluster_state'] == 'ok'
    end
  end

  def wait_replication(clients, max_attempts: 60)
    wait_for_state(clients, max_attempts) do |client|
      flags = hashify_cluster_node_flags(client)
      flags.values.select { |f| f == 'slave' }.size == 3
    end
  end

  def wait_failover(master_key, slave_key, clients, max_attempts: 60)
    wait_for_state(clients, max_attempts) do |client|
      flags = hashify_cluster_node_flags(client)
      flags[master_key] == 'slave' && flags[slave_key] == 'master'
    end
  end

  def wait_replication_delay(clients, timeout_sec)
    timeout_msec = timeout_sec.to_i * 1000
    wait_for_state(clients, clients.size + 1) do |client|
      client.wait(1, timeout_msec) if client.role.first == 'master'
      true
    end
  end

  def wait_cluster_recovering(clients, max_attempts: 60)
    key = 0
    wait_for_state(clients, max_attempts) do |client|
      client.get(key) if client.role.first == 'master'
      true
    rescue Redis::CommandError => err
      if err.message.start_with?('CLUSTERDOWN')
        false
      elsif err.message.start_with?('MOVED')
        key += 1
        false
      else
        true
      end
    end
  end

  def wait_cluster_consistent(max_attempts:)
    max_attempts.times do
      return true if cluster_consistent?

      sleep 0.1
    end
    false
  end

  # Whether every node already sees the exact expected layout: cluster_state ok,
  # the canonical slot ranges owned by the canonical masters — in BOTH the
  # CLUSTER SLOTS and the CLUSTER SHARDS views — and all three replicas attached.
  # Used by #rebuild to skip the expensive teardown.
  def cluster_consistent?
    expected = expected_slots_view(@clients)
    expected_masters = expected.map { |_, _, node_key| node_key }.uniq.sort
    @clients.all? do |client|
      hashify_cluster_info(client)['cluster_state'] == 'ok' &&
        slots_view(client) == expected &&
        shards_masters_view(client) == expected_masters &&
        hashify_cluster_node_flags(client).values.count('slave') == 3
    end && replication_pairs_healthy?
  rescue Redis::BaseError
    false
  end

  # A node can carry the `slave` flag in everyone's CLUSTER NODES view while its
  # replication link is down or points at the wrong primary — later failover tests
  # then lack the healthy pairs they assume. Verify each canonical replica is
  # actually attached to its canonical master with the link up.
  def replication_pairs_healthy?
    take_slaves(@clients).zip(take_masters(@clients)).all? do |replica, master|
      info = replica.info('replication')
      info['role'] == 'slave' &&
        info['master_link_status'] == 'up' &&
        "#{info['master_host']}:#{info['master_port']}" == to_node_key(master)
    end
  end

  # The layout #assign_slots + #replicate produce, as [[start, end, "host:port"], ...].
  def expected_slots_view(clients)
    masters = take_masters(clients)
    slot_slice = SLOT_SIZE / masters.size
    mod = SLOT_SIZE % masters.size
    slot_sizes = Array.new(masters.size, slot_slice)
    mod.downto(1) { |i| slot_sizes[i] += 1 }

    ranges = []
    slot_idx = 0
    masters.zip(slot_sizes).each do |client, size|
      ranges << [slot_idx, slot_idx + size - 1, to_node_key(client)]
      slot_idx += size
    end
    ranges.sort
  end

  # The raw CLUSTER SLOTS reply as [[start, end, "host:port"], ...]: each range is
  # [start, end, master, *replicas] with master = [ip, port, node_id, ...].
  def slots_view(client)
    client.cluster(:slots).map { |range| [range[0], range[1], "#{range[2][0]}:#{range[2][1]}"] }.sort
  end

  # The master set a node advertises via CLUSTER SHARDS — the command
  # redis-cluster-client actually bootstraps its topology from. It is generated
  # separately from CLUSTER SLOTS and can lag it on a freshly rebuilt replica, so
  # SLOTS-only verification lets a client pick up a stale master set and route
  # writes to a demoted node (READONLY). Handles both the RESP2 (flat arrays)
  # and RESP3 (maps) reply shapes.
  def shards_masters_view(client)
    client.cluster(:shards).flat_map do |shard|
      shard = shard.each_slice(2).to_h if shard.is_a?(Array)
      shard.fetch('nodes').filter_map do |node|
        node = node.each_slice(2).to_h if node.is_a?(Array)
        "#{node['ip']}:#{node['port']}" if node['role'] == 'master'
      end
    end.uniq.sort
  end

  # Requires EVERY node to serve the expected master set in its CLUSTER SLOTS reply
  # before the rebuild is considered done. The other waits are per-node liveness
  # checks and give up silently; without this gate a rebuild can return while some
  # node still advertises a stale (pre-failover) view, and any client bootstrapping
  # from that node — including a later `rake test:cluster` invocation against the
  # same containers — routes writes to a demoted node and fails with READONLY.
  # Unlike the other waits, this raises on timeout: a loud failure in the test that
  # disturbed the topology beats silently poisoning whatever runs next.
  def wait_consistent_slots_view(clients, max_attempts: 300)
    expected = take_masters(clients).map { |c| to_node_key(c) }.sort

    clients.each do |client|
      max_attempts.times do |attempt|
        begin
          # Both views must agree: clients bootstrap from CLUSTER SHARDS, which can
          # lag CLUSTER SLOTS on a freshly rebuilt replica.
          slots_ok = slots_view(client).map { |_, _, node_key| node_key }.uniq.sort == expected
          break if slots_ok && shards_masters_view(client) == expected
        rescue Redis::CommandError, Redis::BaseConnectionError
          # CLUSTERDOWN or a node still restarting; keep waiting.
        end

        if attempt == max_attempts - 1
          raise "Cluster rebuild did not converge: #{to_node_key(client)} still reports " \
                "a master set different from #{expected.inspect}"
        end

        sleep 0.1
      end
    end
  end

  def wait_for_state(clients, max_attempts)
    attempt_count = 1
    clients.each do |client|
      attempt_count.step(max_attempts) do |i|
        break if i >= max_attempts

        attempt_count += 1
        break if yield(client)

        sleep 0.1
      end
    end
  end

  def hashify_cluster_info(client)
    client.cluster(:info).split("\r\n").map { |str| str.split(':') }.to_h
  end

  def hashify_cluster_node_flags(client)
    client.cluster(:nodes)
          .split("\n")
          .map { |str| str.split(' ') }
          .map { |arr| [arr[1].split('@').first, (arr[2].split(',') & %w[master slave]).first] }
          .to_h
  end

  def hashify_node_map(client)
    client.cluster(:nodes)
          .split("\n")
          .map { |str| str.split(' ') }
          .map { |arr| [arr[1].split('@').first, arr[0]] }
          .to_h
  end

  def take_masters(clients)
    size = clients.size / 2
    return clients if size < 3

    clients.take(size)
  end

  def take_slaves(clients)
    size = clients.size / 2
    return [] if size < 3

    clients[size..size * 2]
  end

  def take_replication_pairs(clients)
    [take_masters(clients).last, take_slaves(clients).last]
  end

  def find_client(clients, node_key)
    clients.find { |cli| node_key == to_node_key(cli) }
  end

  def to_node_key(client)
    con = client.connection
    "#{con.fetch(:host)}:#{con.fetch(:port)}"
  end
end
