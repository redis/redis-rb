# frozen_string_literal: true

require "helper"

class TestKeyspaceNotificationsChannels < Minitest::Test
  CHANNELS = Redis::KeyspaceNotifications::Channels

  def test_keyspace_channel_for_db_and_key
    assert_equal "__keyspace@3__:user:42", CHANNELS.keyspace("user:42", db: 3)
    assert_equal "__keyspace@0__:mykey", CHANNELS.keyspace("mykey")
  end

  def test_keyevent_channel
    assert_equal "__keyevent@0__:expired", CHANNELS.keyevent("expired")
    assert_equal "__keyevent@15__:del", CHANNELS.keyevent("del", db: 15)
  end

  def test_subkeyspace_channel
    assert_equal "__subkeyspace@0__:myhash", CHANNELS.subkeyspace("myhash")
  end

  def test_subkeyevent_channel
    assert_equal "__subkeyevent@2__:hdel", CHANNELS.subkeyevent("hdel", db: 2)
  end

  def test_subkeyspaceitem_channel_joins_key_and_subkey_with_newline
    assert_equal "__subkeyspaceitem@0__:myhash\nfield1", CHANNELS.subkeyspaceitem("myhash", "field1")
  end

  def test_subkeyspaceitem_rejects_newline_in_key
    assert_raises(ArgumentError) { CHANNELS.subkeyspaceitem("bad\nkey", "field") }
  end

  def test_subkeyspaceitem_allows_newline_in_subkey
    assert_equal "__subkeyspaceitem@0__:k\nf\nield", CHANNELS.subkeyspaceitem("k", "f\nield")
  end

  def test_subkeyspaceevent_channel_joins_event_and_key_with_pipe
    assert_equal "__subkeyspaceevent@0__:hset|user:42", CHANNELS.subkeyspaceevent("hset", "user:42")
  end

  def test_builders_accept_db_wildcard
    assert_equal "__keyevent@*__:*", CHANNELS.keyevent("*", db: "*")
    assert_equal "__keyspace@*__:user:*", CHANNELS.keyspace("user:*", db: "*")
  end

  def test_builders_reject_invalid_db
    assert_raises(ArgumentError) { CHANNELS.keyspace("k", db: -1) }
    assert_raises(ArgumentError) { CHANNELS.keyspace("k", db: "1") }
    assert_raises(ArgumentError) { CHANNELS.keyevent("e", db: 1.5) }
  end

  def test_builders_return_binary_strings
    key = "k\xFF\x00".b
    channel = CHANNELS.keyspace(key)

    assert_equal Encoding::BINARY, channel.encoding
    assert_equal "__keyspace@0__:".b + key, channel
    assert_equal Encoding::BINARY, CHANNELS.keyevent("expired").encoding
  end

  def test_builders_do_not_mutate_arguments
    key = +"mykey"
    CHANNELS.keyspace(key)

    assert_equal "mykey", key
  end
end
