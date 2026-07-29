# frozen_string_literal: true

# RESP2 vs RESP3 for redis-rb across reply-reshape complexity:
#   1. GET               (string — no reshape, baseline)
#   2. HGETALL           (Hashify: flat array -> Hash under RESP2, native map under RESP3)
#   3. ZRANGE WITHSCORES (FloatifyPairs: pairs -> [member, Float] under RESP2, native doubles under RESP3)
#   4. XRANGE            (HashifyStreamEntries — deeply nested reshape)
# Each cell runs single-threaded and multi-threaded (one client per thread).
#
#   DURATION=6 THREADS=8 bundle exec ruby bench/resp_comparison.rb

require "redis"

PORT     = Integer(ENV.fetch("REDIS_PORT", "6381"))
DURATION = Float(ENV.fetch("DURATION", "6"))
THREADS  = Integer(ENV.fetch("THREADS", "8"))
ELEMS    = Integer(ENV.fetch("ELEMENTS", "100"))
DRIVER   = ENV.fetch("DRIVER", "ruby").to_sym
require "hiredis-client" if DRIVER == :hiredis

SKEY = "bench:str"
HKEY = "bench:hash"
ZKEY = "bench:zset"
XKEY = "bench:stream"

def new_client(protocol)
  Redis.new(host: "127.0.0.1", port: PORT, protocol: protocol, driver: DRIVER)
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def seed
  r = new_client(2)
  r.set(SKEY, "x" * 50)
  r.del(HKEY, ZKEY, XKEY)
  fields = ELEMS.times.to_h { |i| ["field#{i}", "value-#{i}-#{'y' * 20}"] }
  r.hset(HKEY, fields)
  r.zadd(ZKEY, ELEMS.times.map { |i| [i * 1.5, "member-#{i}"] })
  ELEMS.times { |i| r.xadd(XKEY, { "sensor" => "s#{i}", "temp" => (20 + i).to_s }) }
  r.close
end

# Sanity: both protocols must produce identical Ruby shapes.
def verify_shapes!
  c2, c3 = new_client(2), new_client(3)
  raise "hgetall mismatch" unless c2.hgetall(HKEY) == c3.hgetall(HKEY)
  raise "zrange mismatch" unless c2.zrange(ZKEY, 0, -1, with_scores: true) == c3.zrange(ZKEY, 0, -1, with_scores: true)
  raise "xrange mismatch" unless c2.xrange(XKEY) == c3.xrange(XKEY)

  [c2, c3].each(&:close)
end

WORKLOADS = {
  "GET (50B string)" => ->(r) { r.get(SKEY) },
  "HGETALL (#{ELEMS} fields)" => ->(r) { r.hgetall(HKEY) },
  "ZRANGE WITHSCORES (#{ELEMS})" => ->(r) { r.zrange(ZKEY, 0, -1, with_scores: true) },
  "XRANGE (#{ELEMS} entries)" => ->(r) { r.xrange(XKEY) }
}.freeze

def cpu_now
  t = Process.times
  t.utime + t.stime
end

def run_cell(protocol, threads, op)
  clients = Array.new(threads) { new_client(protocol) }
  clients.each { |r| 200.times { op.call(r) } } # warmup: connect + JIT
  GC.start
  stop_at = monotonic + DURATION
  counts = Array.new(threads, 0)
  cpu0, t0 = cpu_now, monotonic
  threads.times.map do |i|
    Thread.new do
      r = clients[i]
      n = 0
      n += 1 while op.call(r) && monotonic < stop_at
      counts[i] = n
    end
  end.each(&:join)
  wall, cpu = monotonic - t0, cpu_now - cpu0
  clients.each(&:close)
  total = counts.sum
  { rps: total / wall, us_cpu: (cpu / total) * 1_000_000.0 }
end

seed
verify_shapes!
puts "redis-rb #{Redis::VERSION}  ruby #{RUBY_VERSION}  driver=#{DRIVER}  duration=#{DURATION}s/cell  elements=#{ELEMS}"
puts

[1, THREADS].each do |threads|
  puts "== #{threads} thread#{'s' if threads > 1} =="
  puts format("  %-28s %12s %12s %8s %14s %14s", "workload", "RESP2 RPS", "RESP3 RPS", "Δ RPS", "RESP2 usCPU/op",
              "RESP3 usCPU/op")
  WORKLOADS.each do |label, op|
    r2 = run_cell(2, threads, op)
    r3 = run_cell(3, threads, op)
    delta = (r3[:rps] / r2[:rps] - 1) * 100
    puts format("  %-28s %12.0f %12.0f %+7.1f%% %14.1f %14.1f",
                label, r2[:rps], r3[:rps], delta, r2[:us_cpu], r3[:us_cpu])
  end
  puts
end
