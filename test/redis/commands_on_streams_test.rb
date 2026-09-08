# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/commands_on_streams_test.rb
# @see https://redis.io/commands#stream
class TestCommandsOnStreams < Minitest::Test
  include Helper::Client
  include Lint::Streams

  # Redis 6.2 replies to XAUTOCLAIM with two elements; the third (deleted ids) arrived in 7.0.
  def test_xautoclaim_tolerates_the_two_element_reply_of_redis_6_2
    commands = { xautoclaim: ->(*_) { ['0-0', [['0-1', %w[f v1]], nil, ['0-3', %w[f v3]]]] } }

    redis_mock(commands) do |redis|
      actual = redis.xautoclaim('s1', 'g1', 'c1', 0, '0-0')

      assert_equal '0-0', actual['next']
      assert_equal [['0-1', { 'f' => 'v1' }], ['0-3', { 'f' => 'v3' }]], actual['entries']
      assert_equal [], actual['deleted']
    end
  end

  def test_xautoclaim_with_justid_tolerates_the_two_element_reply_of_redis_6_2
    commands = { xautoclaim: ->(*_) { ['0-0', %w[0-1 0-3]] } }

    redis_mock(commands) do |redis|
      actual = redis.xautoclaim('s1', 'g1', 'c1', 0, '0-0', justid: true)

      assert_equal '0-0', actual['next']
      assert_equal %w[0-1 0-3], actual['entries']
      assert_equal [], actual['deleted']
    end
  end
end
