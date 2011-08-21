# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require "redis/distributed"

setup do
  log = StringIO.new
  init Redis::Distributed.new(NODES, :logger => ::Logger.new(log))
end

test "INFO" do |r|
  expected_keys = %w{
    aof_enabled                   multiplexing_api              vm_enabled
    arch_bits                     process_id
    bgrewriteaof_in_progress      pubsub_channels
    bgsave_in_progress            pubsub_patterns
    blocked_clients               redis_git_dirty
    changes_since_last_save       redis_git_sha1
    client_biggest_input_buf      redis_version
    client_longest_output_list    role
    connected_clients             total_commands_processed
    connected_slaves              total_connections_received
    evicted_keys                  uptime_in_days
    expired_keys                  uptime_in_seconds
    hash_max_zipmap_entries       use_tcmalloc
    hash_max_zipmap_value         used_cpu_sys
    keyspace_hits                 used_cpu_sys_children
    keyspace_misses               used_cpu_user
    last_save_time                used_cpu_user_children
    loading                       used_memory
    lru_clock                     used_memory_human
    mem_fragmentation_ratio       used_memory_rss
  }

  r.info.each { |info| assert expected_keys.sort == info.keys.sort }
end

test "INFO COMMANDSTATS" do |r|
  # Only available on Redis >= 2.9.0
  next if version(r) < 209000

  r.nodes.each { |n| n.config(:resetstat) }
  r.ping # Executed on every node

  r.info(:commandstats).each do |info|
    assert "1" == info["ping"]["calls"]
  end
end

test "MONITOR" do |r|
  begin
    r.monitor
  rescue Exception => ex
  ensure
    assert ex.kind_of?(NotImplementedError)
  end
end

test "ECHO" do |r|
  assert ["foo bar baz\n"] == r.echo("foo bar baz\n")
end
