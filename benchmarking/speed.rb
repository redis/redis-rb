# frozen_string_literal: true

$LOAD_PATH.push File.join(__dir__, 'lib')

require "benchmark"
require "redis"

r = Redis.new
n = (ARGV.shift || 20_000).to_i

elapsed = Benchmark.realtime do
  # n sets, n gets
  n.times do |i|
    key = "foo#{i}"
    r.set(key, key * 10)
    r.get(key)
  end
end

puts '%.2f Kops' % (2 * n / 1000 / elapsed)
