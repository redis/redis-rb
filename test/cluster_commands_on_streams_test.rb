# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/streams'

# ruby -w -Itest test/cluster_commands_on_streams_test.rb
# @see https://redis.io/commands#stream
class TestClusterCommandsOnStreams < Minitest::Test
  include Helper::Cluster
  include Lint::Streams

  def test_xread_with_multiple_keys
    err_msg = "CROSSSLOT Keys in request don't hash to the same slot"
    assert_raises(Redis::CommandError, err_msg) { super }
  end

  def test_xread_with_multiple_keys_and_hash_tags
    redis.xadd('{s}1', { f: 'v01' }, id: '0-1')
    redis.xadd('{s}1', { f: 'v02' }, id: '0-2')
    redis.xadd('{s}2', { f: 'v11' }, id: '1-1')
    redis.xadd('{s}2', { f: 'v12' }, id: '1-2')

    actual = redis.xread(%w[{s}1 {s}2], %w[0-1 1-1])

    assert_equal %w(0-2), actual['{s}1'].map(&:first)
    assert_equal %w(v02), actual['{s}1'].map { |i| i.last['f'] }

    assert_equal %w(1-2), actual['{s}2'].map(&:first)
    assert_equal %w(v12), actual['{s}2'].map { |i| i.last['f'] }
  end

  def test_xreadgroup_with_multiple_keys
    err_msg = "CROSSSLOT Keys in request don't hash to the same slot"
    assert_raises(Redis::CommandError, err_msg) { super }
  end

  def test_xreadgroup_with_multiple_keys_and_hash_tags
    redis.xadd('{s}1', { f: 'v01' }, id: '0-1')
    redis.xgroup(:create, '{s}1', 'g1', '$')
    redis.xadd('{s}2', { f: 'v11' }, id: '1-1')
    redis.xgroup(:create, '{s}2', 'g1', '$')
    redis.xadd('{s}1', { f: 'v02' }, id: '0-2')
    redis.xadd('{s}2', { f: 'v12' }, id: '1-2')

    actual = redis.xreadgroup('g1', 'c1', %w[{s}1 {s}2], %w[> >])

    assert_equal %w(0-2), actual['{s}1'].map(&:first)
    assert_equal %w(v02), actual['{s}1'].map { |i| i.last['f'] }

    assert_equal %w(1-2), actual['{s}2'].map(&:first)
    assert_equal %w(v12), actual['{s}2'].map { |i| i.last['f'] }
  end
end
