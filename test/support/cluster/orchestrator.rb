# frozen_string_literal: true

require_relative '../../../lib/redis'

class ClusterOrchestrator
  SLOT_SIZE = 16384

  def initialize(node_addrs)
    raise 'Redis Cluster requires at least 3 master nodes.' if node_addrs.size < 3
    @clients = node_addrs.map { |addr| Redis.new(url: addr) }
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
    sleep 3
  end

  def down
    flush_all_data(@clients)
    reset_cluster(@clients)
  end

  def failover
    take_slaves(@clients).last.cluster(:failover, :takeover)
    sleep 3
  end

  def start_resharding(slot, src_node_key, dest_node_key)
    node_map = hashify_node_map(@clients.first)
    src_node_id = node_map.fetch(src_node_key)
    src_client = find_client(@clients, src_node_key)
    dest_node_id = node_map.fetch(dest_node_key)
    dest_client = find_client(@clients, dest_node_key)
    dest_host, dest_port = dest_node_key.split(':')

    dest_client.cluster(:setslot, slot, 'IMPORTING', src_node_id)
    src_client.cluster(:setslot, slot, 'MIGRATING', dest_node_id)

    loop do
      keys = src_client.cluster(:getkeysinslot, slot, 100)
      break if keys.empty?
      keys.each { |k| src_client.migrate(k, host: dest_host, port: dest_port) }
      sleep 0.1
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

  def wait_meeting(clients)
    first_cliient = clients.first
    size = clients.size

    loop do
      info = hashify_cluster_info(first_cliient)
      break if info['cluster_known_nodes'].to_i == size
      sleep 0.1
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

  def wait_cluster_building(clients)
    first_cliient = clients.first

    loop do
      info = hashify_cluster_info(first_cliient)
      break if info['cluster_state'] == 'ok'
      sleep 0.1
    end
  end

  def hashify_cluster_info(client)
    client.cluster(:info).split("\r\n").map { |str| str.split(':') }.to_h
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

  def find_client(clients, node_key)
    clients.find do |cli|
      con = cli.connection
      node_key == "#{con.fetch(:host)}:#{con.fetch(:port)}"
    end
  end
end
