# frozen_string_literal: true

require_relative '../../../lib/redis'

class ClusterOrchestrator
  SLOT_SIZE = 16384

  def initialize(node_addrs, timeout: 30.0)
    raise 'Redis Cluster requires at least 3 master nodes.' if node_addrs.size < 3
    @clients = node_addrs.map do |addr|
      Redis.new(url: addr,
                timeout: timeout,
                reconnect_attempts: 10,
                reconnect_delay: 1.5,
                reconnect_delay_max: 10.0)
    end
    @timeout = timeout
  end

  def rebuild
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
  end

  def down
    flush_all_data(@clients)
    reset_cluster(@clients)
  end

  def failover
    master, slave = take_replication_pairs(@clients)
    wait_replication_delay(@clients, @timeout)
    slave.cluster(:failover, :takeover)
    wait_failover(to_node_key(master), to_node_key(slave), @clients)
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
        begin
          src_client.migrate(k, host: dest_host, port: dest_port)
        rescue Redis::CommandError => err
          raise unless err.message.start_with?('IOERR')
          src_client.migrate(k, host: dest_host, port: dest_port, replace: true) # retry once
        ensure
          keys_count -= 1
        end
      end
    end
  end

  def finish_resharding(slot, dest_node_key)
    node_map = hashify_node_map(@clients.first)
    @clients.first.cluster(:setslot, slot, 'NODE', node_map.fetch(dest_node_key))
  end

  def close
    @clients.each(&:quit)
  end

  private

  def flush_all_data(clients)
    clients.each do |c|
      begin
        c.flushall
      rescue Redis::CommandError
        # READONLY You can't write against a read only slave.
        nil
      end
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
      begin
        c.cluster('set-config-epoch', i + 1)
      rescue Redis::CommandError
        # ERR Node config epoch is already non-zero
        nil
      end
    end
  end

  def meet_each_other(clients)
    first_cliient = clients.first
    target_info = first_cliient.connection
    target_host = target_info.fetch(:host)
    target_port = target_info.fetch(:port)

    clients.each do |client|
      next if first_cliient.id == client.id
      client.cluster(:meet, target_host, target_port)
    end
  end

  def wait_meeting(clients, max_attempts: 600)
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

  def wait_cluster_building(clients, max_attempts: 600)
    wait_for_state(clients, max_attempts) do |client|
      info = hashify_cluster_info(client)
      info['cluster_state'] == 'ok'
    end
  end

  def wait_replication(clients, max_attempts: 600)
    wait_for_state(clients, max_attempts) do |client|
      flags = hashify_cluster_node_flags(client)
      flags.values.select { |f| f == 'slave' }.size == 3
    end
  end

  def wait_failover(master_key, slave_key, clients, max_attempts: 600)
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

  def wait_cluster_recovering(clients, max_attempts: 600)
    key = 0
    wait_for_state(clients, max_attempts) do |client|
      begin
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
