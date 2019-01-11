# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/streams'

class TestDistributedCommandsOnStreams < Test::Unit::TestCase
  include Helper::Distributed
  include Lint::Streams

  def test_xread_with_multiple_node_keys
    redis.xadd('key1', { f: 'v01' }, id: '0-1')
    redis.xadd('key1', { f: 'v02' }, id: '0-2')
    redis.xadd('key4', { f: 'v11' }, id: '1-1')
    redis.xadd('key4', { f: 'v12' }, id: '1-2')

    assert_raise(Redis::Distributed::CannotDistribute) { redis.xread(%w[key1 key4], %w[0-1 1-1]) }
  end

  def test_xreadgroup_with_multiple_node_keys
    redis.xadd('key1', { f: 'v01' }, id: '0-1')
    redis.xgroup(:create, 'key1', 'g1', '$')
    redis.xadd('key4', { f: 'v11' }, id: '1-1')
    redis.xgroup(:create, 'key4', 'g1', '$')
    redis.xadd('key1', { f: 'v02' }, id: '0-2')
    redis.xadd('key4', { f: 'v12' }, id: '1-2')

    assert_raise(Redis::Distributed::CannotDistribute) { redis.xreadgroup('g1', 'c1', %w[key1 key4], %w[> >]) }
  end
end
