# frozen_string_literal: true

require_relative 'helper'

class TestDistributedPartitioner < Test::Unit::TestCase
  include Helper::Distributed

  def build_client
    nodes = ["redis://127.0.0.1:#{PORT}/#{DB}", "redis://127.0.0.1:#{NODE2_PORT}/#{DB}"]
    opts = { distributed: { nodes: nodes }, timeout: TIMEOUT }
    Redis::Distributed::Partitioner.new(opts)
  end

  def test_key_extraction_with_get_command
    c = build_client
    assert_equal %w[foo], c.send(:extract_keys, %w[get foo])
    assert_equal %w[{foo}bar], c.send(:extract_keys, %w[get {foo}bar])
    assert_equal %w[fo{oba}r], c.send(:extract_keys, %w[get fo{oba}r])
  end

  def test_key_extraction_with_set_command
    c = build_client
    assert_equal %w[foo], c.send(:extract_keys, %w[set foo 1])
    assert_equal %w[{foo}bar], c.send(:extract_keys, %w[set {foo}bar 1])
    assert_equal %w[fo{oba}r], c.send(:extract_keys, %w[set fo{oba}r 1])
  end

  def test_key_extraction_with_mget_command
    c = build_client
    assert_equal %w[foo bar], c.send(:extract_keys, %w[mget foo bar])
    assert_equal %w[{key}foo {key}bar], c.send(:extract_keys, %w[mget {key}foo {key}bar])
    assert_equal %w[{key1}foo {key2}bar], c.send(:extract_keys, %w[mget {key1}foo {key2}bar])
    assert_equal %w[ke{y1f}oo ke{y2b}ar], c.send(:extract_keys, %w[mget ke{y1f}oo ke{y2b}ar])
  end

  def test_key_extraction_with_mset_command
    c = build_client
    assert_equal %w[foo bar], c.send(:extract_keys, %w[mset foo 1 bar 2])
    assert_equal %w[{key}foo {key}bar], c.send(:extract_keys, %w[mset {key}foo 1 {key}bar 2])
    assert_equal %w[{key1}foo {key2}bar], c.send(:extract_keys, %w[mset {key1}foo 1 {key2}bar 2])
    assert_equal %w[ke{y1f}oo ke{y2b}ar], c.send(:extract_keys, %w[mset ke{y1f}oo 1 ke{y2b}ar 2])
  end

  def test_key_extraction_with_pubsub_command
    c = build_client
    assert_equal %w[chan], c.send(:extract_keys, [:publish, 'chan', 'Hi'])
    assert_equal %w[chan], c.send(:extract_keys, [:subscribe, 'chan'])
    assert_equal %w[chan1 chan2], c.send(:extract_keys, [:subscribe, 'chan1', 'chan2'])
    assert_equal %w[{chan}1 {chan}2], c.send(:extract_keys, [:subscribe, '{chan}1', '{chan}2'])

    assert_equal [], c.send(:extract_keys, [:psubscribe, 'channel'])
    assert_equal [], c.send(:extract_keys, [:pubsub, 'channels', '*'])
    assert_equal [], c.send(:extract_keys, [:punsubscribe, 'channel'])
    assert_equal [], c.send(:extract_keys, [:unsubscribe, 'channel'])
  end

  def test_key_extraction_with_blocking_command
    c = build_client
    assert_equal %w[key1 key2], c.send(:extract_keys, [:blpop, 'key1', 'key2', 1])

    target_version('3.2.0') do
      # There is a bug Redis 3.0's COMMAND command
      assert_equal %w[key1 key2], c.send(:extract_keys, [:brpop, 'key1', 'key2', 1])
    end

    assert_equal %w[key1 key2], c.send(:extract_keys, [:brpoplpush, 'key1', 'key2', 1])

    target_version('5.0.0') do
      assert_equal %w[key1 key2], c.send(:extract_keys, [:bzpopmin, 'key1', 'key2', 1])
      assert_equal %w[key1 key2], c.send(:extract_keys, [:bzpopmax, 'key1', 'key2', 1])
    end
  end

  def test_key_extraction_with_keyless_command
    c = build_client
    assert_equal [], c.send(:extract_keys, [:auth, 'password'])
    assert_equal [], c.send(:extract_keys, %i[client kill])
    assert_equal [], c.send(:extract_keys, %i[cluster addslots])
    assert_equal [], c.send(:extract_keys, %i[command])
    assert_equal [], c.send(:extract_keys, %i[command count])
    assert_equal [], c.send(:extract_keys, %i[config get])
    assert_equal [], c.send(:extract_keys, %i[debug segfault])
    assert_equal [], c.send(:extract_keys, [:echo, 'Hello World'])
    assert_equal [], c.send(:extract_keys, [:flushall, 'ASYNC'])
    assert_equal [], c.send(:extract_keys, [:flushdb, 'ASYNC'])
    assert_equal [], c.send(:extract_keys, [:info, 'cluster'])
    assert_equal [], c.send(:extract_keys, %i[memory doctor])
    assert_equal [], c.send(:extract_keys, [:ping, 'Hi'])
    assert_equal [], c.send(:extract_keys, %w[script exists sha1 sha1])
    assert_equal [], c.send(:extract_keys, [:select, 1])
    assert_equal [], c.send(:extract_keys, [:shutdown, 'SAVE'])
    assert_equal [], c.send(:extract_keys, [:slaveof, '127.0.0.1', 6379])
    assert_equal [], c.send(:extract_keys, [:slowlog, 'get', 2])
    assert_equal [], c.send(:extract_keys, [:swapdb, 0, 1])
    assert_equal [], c.send(:extract_keys, [:wait, 1, 0])
  end

  def test_key_extraction_with_command_having_various_positional_key
    c = build_client
    assert_equal %w[key1 key2],      c.send(:extract_keys, [:eval, 'script', 2, 'key1', 'key2', 'first', 'second'])
    assert_equal [],                 c.send(:extract_keys, [:eval, 'return 0', 0])
    assert_equal %w[key1 key2],      c.send(:extract_keys, [:evalsha, 'sha1', 2, 'key1', 'key2', 'first', 'second'])
    assert_equal [],                 c.send(:extract_keys, [:evalsha, 'return 0', 0])
    assert_equal [],                 c.send(:extract_keys, [:migrate, '127.0.0.1', 6379, 'key1', 0, 5000])
    assert_equal %w[key1],           c.send(:extract_keys, [:object, 'refcount', 'key1'])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zinterstore, 'dest', 2, 'key1', 'key2', 'WEIGHTS', 2, 3])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zinterstore, 'dest', 2, 'key1', 'key2', 'AGGREGATE', 'sum'])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zinterstore, 'dest', 2, 'key1', 'key2', 'WEIGHTS', 2, 3, 'AGGREGATE', 'sum'])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zinterstore, 'dest', 2, 'key1', 'key2'])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zunionstore, 'dest', 2, 'key1', 'key2', 'WEIGHTS', 2, 3])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zunionstore, 'dest', 2, 'key1', 'key2', 'AGGREGATE', 'sum'])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zunionstore, 'dest', 2, 'key1', 'key2', 'WEIGHTS', 2, 3, 'AGGREGATE', 'sum'])
    assert_equal %w[dest key1 key2], c.send(:extract_keys, [:zunionstore, 'dest', 2, 'key1', 'key2'])

    assert_equal %w[key1 key2 key3 key4 key5], c.send(:extract_keys, [:sort, 'key1', 'BY', 'key2', 'LIMIT', 0, 5, 'GET', 'key3', 'GET', 'key4', 'DESC', 'ALPHA', 'STORE', 'key5']).sort

    target_version('4.0.0') do
      assert_equal %w[key1], c.send(:extract_keys, [:memory, :usage, 'key1'])
    end

    target_version('5.0.0') do
      assert_equal %w[s1 s2], c.send(:extract_keys, [:xread, 'COUNT', 2, 'STREAMS', 's1', 's2', 0, 0])
      assert_equal %w[s1],    c.send(:extract_keys, [:xread, 'COUNT', 2, 'STREAMS', 's1', 0])
      assert_equal %w[s1 s2], c.send(:extract_keys, [:xreadgroup, 'GROUP', 'mygroup', 'Bob', 'COUNT', 2, 'STREAMS', 's1', 's2', '>', '>'])
      assert_equal %w[s1],    c.send(:extract_keys, [:xreadgroup, 'GROUP', 'mygroup', 'Bob', 'COUNT', 2, 'STREAMS', 's1', '>'])
    end
  end

  def test_multiple_node_handling_for_mget_command
    c = build_client
    range = (1..100)
    range.each { |i| c.call(['set', "key#{i}", i]) }
    keys = range.map { |i| "key#{i}" }
    expected = range.map(&:to_s)
    actual = c.send(:send_mget_command, ['mget'] + keys)
    assert_equal expected, actual
  end

  def test_multiple_node_handling_for_mget_command_with_tag
    c = build_client
    range = (1..100)
    range.each { |i| c.call(['set', "{key}#{i}", i]) }
    keys = range.map { |i| "{key}#{i}" }
    expected = range.map(&:to_s)
    actual = c.send(:send_mget_command, ['mget'] + keys)
    assert_equal expected, actual
  end

  def test_send_command
    c = build_client
    assert_raise(Redis::Distributed::CannotDistribute) { c.send(:send_command, ['eval', 'return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}', '2', 'key1', 'key4', 'first', 'second']) }
  end

  def test_assert_same_node!
    c = build_client
    assert_raise(Redis::Distributed::CannotDistribute) { c.send(:assert_same_node!, %w[key1 key4]) }
    assert_equal nil, c.send(:assert_same_node!, %w[key1 key2])
    assert_equal nil, c.send(:assert_same_node!, %w[key3 key4])
    assert_raise(Redis::Distributed::CannotDistribute) { c.send(:assert_same_node!, %w[a b]) }
    assert_equal nil, c.send(:assert_same_node!, %w[b c])
    assert_equal nil, c.send(:assert_same_node!, %w[c d])
    assert_equal nil, c.send(:assert_same_node!, %w[foo bar baz zap])
    assert_equal nil, c.send(:assert_same_node!, %w[hoge fuga])
  end
end
