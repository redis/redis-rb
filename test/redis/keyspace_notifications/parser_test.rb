# frozen_string_literal: true

require "helper"

class TestKeyspaceNotificationsParser < Minitest::Test
  CHANNELS = Redis::KeyspaceNotifications::Channels
  PARSER = Redis::KeyspaceNotifications::Parser
  PARSE_ERROR = Redis::KeyspaceNotifications::ParseError

  def test_parses_keyspace
    notification = PARSER.parse("__keyspace@0__:mykey", "set")

    assert_equal :keyspace, notification.family
    assert_equal 0, notification.db
    assert_equal "set", notification.event
    assert_equal "mykey", notification.key
    assert_empty notification.subkeys
  end

  def test_parses_keyevent
    notification = PARSER.parse("__keyevent@15__:expired", "session:42")

    assert_equal :keyevent, notification.family
    assert_equal 15, notification.db
    assert_equal "expired", notification.event
    assert_equal "session:42", notification.key
    assert_empty notification.subkeys
  end

  def test_parses_key_containing_colons
    notification = PARSER.parse("__keyspace@0__:a:b:c__:d", "del")

    assert_equal "a:b:c__:d", notification.key
  end

  def test_parses_subkeyspace_multiple_subkeys
    notification = PARSER.parse("__subkeyspace@0__:myhash", "hset|4:name,5:email")

    assert_equal :subkeyspace, notification.family
    assert_equal "hset", notification.event
    assert_equal "myhash", notification.key
    assert_equal %w[name email], notification.subkeys
  end

  def test_parses_subkeyevent
    notification = PARSER.parse("__subkeyevent@0__:hdel", "6:myhash|4:name,5:email")

    assert_equal :subkeyevent, notification.family
    assert_equal "hdel", notification.event
    assert_equal "myhash", notification.key
    assert_equal %w[name email], notification.subkeys
  end

  def test_parses_subkeyevent_key_containing_pipe
    notification = PARSER.parse("__subkeyevent@0__:hdel", "7:my|hash|4:name")

    assert_equal "my|hash", notification.key
    assert_equal %w[name], notification.subkeys
  end

  def test_parses_subkeyspaceitem
    notification = PARSER.parse("__subkeyspaceitem@0__:myhash\nname", "hset")

    assert_equal :subkeyspaceitem, notification.family
    assert_equal "hset", notification.event
    assert_equal "myhash", notification.key
    assert_equal %w[name], notification.subkeys
    assert_equal "name", notification.subkey
  end

  def test_parses_subkeyspaceitem_subkey_containing_newline
    notification = PARSER.parse("__subkeyspaceitem@0__:myhash\nfie\nld", "hset")

    assert_equal "myhash", notification.key
    assert_equal "fie\nld", notification.subkey
  end

  def test_parses_subkeyspaceevent
    notification = PARSER.parse("__subkeyspaceevent@0__:hset|user:42", "4:name,5:email")

    assert_equal :subkeyspaceevent, notification.family
    assert_equal "hset", notification.event
    assert_equal "user:42", notification.key
    assert_equal %w[name email], notification.subkeys
  end

  def test_parses_subkeyspaceevent_key_containing_pipe
    notification = PARSER.parse("__subkeyspaceevent@0__:hset|user|42", "4:name")

    assert_equal "hset", notification.event
    assert_equal "user|42", notification.key
  end

  def test_parses_subkeys_containing_delimiters
    subkey = "a|b,c:d\ne"
    notification = PARSER.parse("__subkeyspace@0__:h", "hset|#{subkey.bytesize}:#{subkey},1:x")

    assert_equal [subkey, "x"], notification.subkeys
  end

  def test_parses_binary_keys_and_subkeys
    key = "k\xFF\x00|,:\n".b
    subkey = "\xC3\x28".b # invalid UTF-8
    payload = "#{key.bytesize}:#{key}|#{subkey.bytesize}:#{subkey}".b
    notification = PARSER.parse("__subkeyevent@0__:hdel", payload)

    assert_equal key, notification.key
    assert_equal [subkey], notification.subkeys
  end

  def test_preserves_duplicate_subkeys_in_order
    notification = PARSER.parse("__subkeyspace@0__:h", "hset|1:b,1:a,1:b")

    assert_equal %w[b a b], notification.subkeys
  end

  def test_single_subkey_still_length_prefixed
    notification = PARSER.parse("__subkeyspace@0__:h", "hset|4:name")

    assert_equal %w[name], notification.subkeys
  end

  def test_parses_empty_subkey
    notification = PARSER.parse("__subkeyspace@0__:h", "hset|0:")

    assert_equal [""], notification.subkeys
  end

  def test_accepts_db_wildcard_channel
    notification = PARSER.parse("__keyevent@*__:expired", "k")

    assert_equal "*", notification.db
    assert_equal "expired", notification.event
  end

  def test_carries_pattern_and_raw_strings
    notification = PARSER.parse("__keyspace@0__:mykey", "set", pattern: "__keyspace@0__:*")

    assert_equal "__keyspace@0__:*", notification.pattern
    assert_equal "__keyspace@0__:mykey", notification.channel
    assert_equal "set", notification.payload
  end

  def test_returns_nil_for_non_notification_channel
    assert_nil PARSER.parse("some-channel", "hello")
    assert_nil PARSER.parse("__keyspace@x__:k", "set") # malformed db is not a notification header
    assert_nil PARSER.parse("keyspace@0__:k", "set")
  end

  def test_raises_on_truncated_subkey_value
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspace@0__:h", "hset|9:short") }
  end

  def test_raises_on_non_digit_length
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspace@0__:h", "hset|x:abc") }
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspace@0__:h", "hset|:abc") }
  end

  def test_raises_on_missing_pipe
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspace@0__:h", "hset") }
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyevent@0__:hdel", "6:myhash4:name") }
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspaceevent@0__:hset", "4:name") }
  end

  def test_raises_on_missing_comma_between_subkeys
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspace@0__:h", "hset|1:a1:b") }
  end

  def test_raises_on_missing_newline_in_subkeyspaceitem
    assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspaceitem@0__:myhash", "hset") }
  end

  def test_parse_error_carries_channel_and_payload
    error = assert_raises(PARSE_ERROR) { PARSER.parse("__subkeyspace@0__:h", "hset|9:short") }

    assert_equal "__subkeyspace@0__:h", error.channel
    assert_equal "hset|9:short", error.payload
  end

  def test_round_trips_builder_output
    key = "user:42"
    assert_equal key, PARSER.parse(CHANNELS.keyspace(key, db: 3), "set").key
    assert_equal "expired", PARSER.parse(CHANNELS.keyevent("expired"), key).event
    assert_equal key, PARSER.parse(CHANNELS.subkeyspace(key), "hset|1:f").key

    notification = PARSER.parse(CHANNELS.subkeyspaceitem(key, "field"), "hset")
    assert_equal key, notification.key
    assert_equal "field", notification.subkey

    notification = PARSER.parse(CHANNELS.subkeyspaceevent("hset", key), "1:f")
    assert_equal "hset", notification.event
    assert_equal key, notification.key
  end

  def test_does_not_mutate_input_strings
    channel = +"__keyspace@0__:mykey"
    payload = +"set"
    PARSER.parse(channel, payload)

    assert_equal "__keyspace@0__:mykey", channel
    assert_equal "set", payload
    assert_equal Encoding::UTF_8, channel.encoding
  end
end
