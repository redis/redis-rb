# frozen_string_literal: true

require 'redis'
require 'benchmark'

N = (ARGV.first || 100_000).to_i

available_slots = {
  "127.0.0.1:7000" => [0..5460],
  "127.0.0.1:7003" => [0..5460],
  "127.0.0.1:7001" => [5461..10_922],
  "127.0.0.1:7004" => [5461..10_922],
  "127.0.0.1:7002" => [10_923..16_383],
  "127.0.0.1:7005" => [10_923..16_383]
}

node_flags = {
  "127.0.0.1:7000" => "master",
  "127.0.0.1:7002" => "master",
  "127.0.0.1:7001" => "master",
  "127.0.0.1:7005" => "slave",
  "127.0.0.1:7004" => "slave",
  "127.0.0.1:7003" => "slave"
}

Benchmark.bmbm do |bm|
  bm.report('Slot.new') do
    allocs = GC.stat(:total_allocated_objects)

    N.times do
      Redis::Cluster::Slot.new(available_slots, node_flags, false)
    end

    puts GC.stat(:total_allocated_objects) - allocs
  end
end
