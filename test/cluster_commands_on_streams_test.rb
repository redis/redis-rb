# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_streams_test.rb
# @see https://redis.io/commands#stream
class TestClusterCommandsOnStreams < Test::Unit::TestCase
  include Helper::Cluster

  MIN_REDIS_VERSION = '4.9.0'
  ENTRY_ID_FORMAT = /\d+-\d+/

  def setup
    super
    add_some_entries_to_streams_without_hashtag
    add_some_entries_to_streams_with_hashtag
  end

  def add_some_entries_to_streams_without_hashtag
    target_version(MIN_REDIS_VERSION) do
      redis.xadd('stream1', '*', 'name', 'John', 'surname', 'Connor')
      redis.xadd('stream1', '*', 'name', 'Sarah', 'surname', 'Connor')
      redis.xadd('stream1', '*', 'name', 'Miles', 'surname', 'Dyson')
      redis.xadd('stream1', '*', 'name', 'Peter', 'surname', 'Silberman')
    end
  end

  def add_some_entries_to_streams_with_hashtag
    target_version(MIN_REDIS_VERSION) do
      redis.xadd('{stream}1', '*', 'name', 'John', 'surname', 'Connor')
      redis.xadd('{stream}1', '*', 'name', 'Sarah', 'surname', 'Connor')
      redis.xadd('{stream}1', '*', 'name', 'Miles', 'surname', 'Dyson')
      redis.xadd('{stream}1', '*', 'name', 'Peter', 'surname', 'Silberman')
    end
  end

  def assert_stream_entry(actual, expected_name, expected_surname)
    actual_key = actual.keys.first
    actual_values = actual[actual_key]

    assert_match ENTRY_ID_FORMAT, actual_key
    assert_equal expected_name, actual_values['name']
    assert_equal expected_surname, actual_values['surname']
  end

  def assert_stream_pending(actual, expected_size_of_group, expected_consumer_name, expected_size_of_consumer)
    assert_equal expected_size_of_group, actual[:size]
    assert_match ENTRY_ID_FORMAT, actual[:min_entry_id]
    assert_match ENTRY_ID_FORMAT, actual[:max_entry_id]
    assert_equal({ expected_consumer_name => expected_size_of_consumer }, actual[:consumers])
  end

  # TODO: Remove this helper method when we implement streams interfaces
  def hashify_stream_entries(reply)
    reply.map do |entry_id, values|
      [entry_id, Hash[values.each_slice(2).to_a]]
    end.to_h
  end

  # TODO: Remove this helper method when we implement streams interfaces
  def hashify_streams(reply)
    reply.map do |stream_key, entries|
      [stream_key, hashify_stream_entries(entries)]
    end.to_h
  end

  # TODO: Remove this helper method when we implement streams interfaces
  def hashify_stream_pendings(reply)
    {
      size: reply.first,
      min_entry_id: reply[1],
      max_entry_id: reply[2],
      consumers: Hash[reply[3]]
    }
  end

  def test_xadd
    target_version(MIN_REDIS_VERSION) do
      assert_match ENTRY_ID_FORMAT, redis.xadd('mystream', '*', 'type', 'T-800', 'model', '101')
      assert_match ENTRY_ID_FORMAT, redis.xadd('my{stream}', '*', 'type', 'T-1000')
    end
  end

  def test_xrange
    target_version(MIN_REDIS_VERSION) do
      actual = redis.xrange('stream1', '-', '+', 'COUNT', 1)
      actual = hashify_stream_entries(actual) # TODO: Remove this step when we implement streams interfaces
      assert_stream_entry(actual, 'John', 'Connor')

      actual = redis.xrange('{stream}1', '-', '+', 'COUNT', 1)
      actual = hashify_stream_entries(actual) # TODO: Remove this step when we implement streams interfaces
      assert_stream_entry(actual, 'John', 'Connor')
    end
  end

  def test_xrevrange
    target_version(MIN_REDIS_VERSION) do
      actual = redis.xrevrange('stream1', '+', '-', 'COUNT', 1)
      actual = hashify_stream_entries(actual) # TODO: Remove this step when we implement streams interfaces
      assert_stream_entry(actual, 'Peter', 'Silberman')

      actual = redis.xrevrange('{stream}1', '+', '-', 'COUNT', 1)
      actual = hashify_stream_entries(actual) # TODO: Remove this step when we implement streams interfaces
      assert_stream_entry(actual, 'Peter', 'Silberman')
    end
  end

  def test_xlen
    target_version(MIN_REDIS_VERSION) do
      assert_equal 4, redis.xlen('stream1')
      assert_equal 4, redis.xlen('{stream}1')
    end
  end

  def test_xread
    target_version(MIN_REDIS_VERSION) do
      # non blocking without hashtag
      actual = redis.xread('COUNT', 1, 'STREAMS', 'stream1', 0)
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal 'stream1', actual.keys.first
      assert_stream_entry(actual['stream1'], 'John', 'Connor')

      # blocking without hashtag
      actual = redis.xread('COUNT', 1, 'BLOCK', 1, 'STREAMS', 'stream1', 0)
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal 'stream1', actual.keys.first
      assert_stream_entry(actual['stream1'], 'John', 'Connor')

      # non blocking with hashtag
      actual = redis.xread('COUNT', 1, 'STREAMS', '{stream}1', 0)
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal '{stream}1', actual.keys.first
      assert_stream_entry(actual['{stream}1'], 'John', 'Connor')

      # blocking with hashtag
      actual = redis.xread('COUNT', 1, 'BLOCK', 1, 'STREAMS', '{stream}1', 0)
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal '{stream}1', actual.keys.first
      assert_stream_entry(actual['{stream}1'], 'John', 'Connor')
    end
  end

  def test_xreadgroup
    target_version(MIN_REDIS_VERSION) do
      # non blocking without hashtag
      redis.xgroup('create', 'stream1', 'mygroup1', '$')
      add_some_entries_to_streams_without_hashtag
      actual = redis.xreadgroup('GROUP', 'mygroup1', 'T-1000', 'COUNT', 1, 'STREAMS', 'stream1', '>')
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal 'stream1', actual.keys.first
      assert_stream_entry(actual['stream1'], 'John', 'Connor')

      # blocking without hashtag
      redis.xgroup('create', 'stream1', 'mygroup2', '$')
      add_some_entries_to_streams_without_hashtag
      actual = redis.xreadgroup('GROUP', 'mygroup2', 'T-800', 'COUNT', 1, 'BLOCK', 1, 'STREAMS', 'stream1', '>')
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal 'stream1', actual.keys.first
      assert_stream_entry(actual['stream1'], 'John', 'Connor')

      # non blocking with hashtag
      redis.xgroup('create', '{stream}1', 'mygroup3', '$')
      add_some_entries_to_streams_with_hashtag
      actual = redis.xreadgroup('GROUP', 'mygroup3', 'T-1000', 'COUNT', 1, 'STREAMS', '{stream}1', '>')
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal '{stream}1', actual.keys.first
      assert_stream_entry(actual['{stream}1'], 'John', 'Connor')

      # blocking with hashtag
      redis.xgroup('create', '{stream}1', 'mygroup4', '$')
      add_some_entries_to_streams_with_hashtag
      actual = redis.xreadgroup('GROUP', 'mygroup4', 'T-800', 'COUNT', 1, 'BLOCK', 1, 'STREAMS', '{stream}1', '>')
      actual = hashify_streams(actual) # TODO: Remove this step when we implement streams interfaces
      assert_equal '{stream}1', actual.keys.first
      assert_stream_entry(actual['{stream}1'], 'John', 'Connor')
    end
  end

  def test_xpending
    target_version(MIN_REDIS_VERSION) do
      redis.xgroup('create', 'stream1', 'mygroup1', '$')
      add_some_entries_to_streams_without_hashtag
      redis.xreadgroup('GROUP', 'mygroup1', 'T-800', 'COUNT', 1, 'STREAMS', 'stream1', '>')
      actual = redis.xpending('stream1', 'mygroup1')
      actual = hashify_stream_pendings(actual) # TODO: Remove this step when we implement streams interfaces
      assert_stream_pending(actual, 1, 'T-800', '1')

      redis.xgroup('create', '{stream}1', 'mygroup2', '$')
      add_some_entries_to_streams_with_hashtag
      redis.xreadgroup('GROUP', 'mygroup2', 'T-800', 'COUNT', 1, 'STREAMS', '{stream}1', '>')
      actual = redis.xpending('{stream}1', 'mygroup2')
      actual = hashify_stream_pendings(actual) # TODO: Remove this step when we implement streams interfaces
      assert_stream_pending(actual, 1, 'T-800', '1')
    end
  end
end
