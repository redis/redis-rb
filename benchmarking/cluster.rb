# frozen_string_literal: true

# Execute the following commands before execution
#
# `$ make start`
# `$ make start_cluster`
# `$ make create_cluster`

require 'redis'
require 'benchmark'

HOST            = '127.0.0.1'
STANDALONE_PORT = 6381
CLUSTER_PORT    = 7000
N               = (ARGV.first || 100000).to_i

rn = Redis.new(host: HOST, port: STANDALONE_PORT)
rc = Redis.new(host: HOST, port: CLUSTER_PORT)
rm = Redis.new(cluster: %W[redis://#{HOST}:#{CLUSTER_PORT}])
rs = Redis.new(cluster: %W[redis://#{HOST}:#{CLUSTER_PORT}], replica: true)

Benchmark.bmbm do |bm|
  bm.report('client: normal,  server: standalone, command: SET,  key: fixed') do
    N.times { rn.set('foo', '42') }
  end

  bm.report('client: normal,  server: standalone, command: GET,  key: fixed') do
    N.times { rn.get('foo') }
  end

  bm.report('client: normal,  server: cluster,    command: SET,  key: fixed') do
    N.times { rc.set('bar', '42') }
  end

  bm.report('client: normal,  server: cluster,    command: GET,  key: fixed') do
    N.times { rc.get('bar') }
  end

  bm.report('client: cluster, server: cluster,    command: SET,  key: fixed') do
    N.times { rm.set('baz', '42') }
  end

  rm.wait(1, 0)
  bm.report('client: cluster, server: cluster,    command: GET,  key: fixed') do
    N.times { rm.get('baz') }
  end

  bm.report('client: cluster, server: cluster,    command: SET,  key: fixed,    replica: true') do
    N.times { rs.set('zap', '42') }
  end

  rs.wait(1, 0)
  bm.report('client: cluster, server: cluster,    command: GET,  key: fixed,    replica: true') do
    N.times { rs.get('zap') }
  end

  bm.report('client: normal,  server: standalone, command: SET,  key: variable') do
    N.times { |i| rn.set("foo:#{i}", '42') }
  end

  bm.report('client: normal,  server: standalone, command: GET,  key: variable') do
    N.times { |i| rn.get("foo:#{i}") }
  end

  bm.report('client: cluster, server: cluster,    command: SET,  key: variable') do
    N.times { |i| rm.set("bar:#{i}", '42') }
  end

  rm.wait(1, 0)
  bm.report('client: cluster, server: cluster,    command: GET,  key: variable') do
    N.times { |i| rm.get("bar:#{i}") }
  end

  bm.report('client: cluster, server: cluster,    command: SET,  key: variable, replica: true') do
    N.times { |i| rs.set("baz:#{i}", '42') }
  end

  rs.wait(1, 0)
  bm.report('client: cluster, server: cluster,    command: GET,  key: variable, replica: true') do
    N.times { |i| rs.get("baz:#{i}") }
  end

  rn.set('bar', 0)
  bm.report('client: normal,  server: standalone, command: INCR, key: fixed') do
    N.times { rn.incr('bar') }
  end

  rc.set('bar', 0)
  bm.report('client: normal,  server: cluster,    command: INCR, key: fixed') do
    N.times { rc.incr('bar') }
  end

  rm.set('bar', 0)
  bm.report('client: cluster, server: cluster,    command: INCR, key: fixed') do
    N.times { rm.incr('bar') }
  end
end
