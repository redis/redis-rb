# frozen_string_literal: true

require "helper"

class TestKeyspaceNotificationsNotification < Minitest::Test
  def build(**overrides)
    defaults = {
      family: :keyspace, db: 0, event: "set", key: "mykey",
      channel: "__keyspace@0__:mykey", payload: "set"
    }
    Redis::KeyspaceNotifications::Notification.new(**defaults.merge(overrides))
  end

  def test_readers
    notification = build(subkeys: %w[a b], pattern: "__keyspace@0__:*")

    assert_equal :keyspace, notification.family
    assert_equal 0, notification.db
    assert_equal "set", notification.event
    assert_equal "mykey", notification.key
    assert_equal %w[a b], notification.subkeys
    assert_equal "__keyspace@0__:mykey", notification.channel
    assert_equal "set", notification.payload
    assert_equal "__keyspace@0__:*", notification.pattern
  end

  def test_value_equality
    assert_equal build, build
    refute_equal build, build(event: "del")
    assert build.eql?(build)
    assert_equal build.hash, build.hash
  end

  def test_to_h
    hash = build.to_h

    assert_equal :keyspace, hash[:family]
    assert_equal "mykey", hash[:key]
    assert_equal [], hash[:subkeys]
    assert_nil hash[:pattern]
  end

  def test_subkey_convenience
    assert_nil build.subkey
    assert_equal "field1", build(family: :subkeyspaceitem, subkeys: ["field1"]).subkey
  end

  def test_subkey_family_predicate
    refute_predicate build, :subkey_family?
    refute_predicate build(family: :keyevent), :subkey_family?
    assert_predicate build(family: :subkeyspace), :subkey_family?
    assert_predicate build(family: :subkeyspaceitem), :subkey_family?
  end

  def test_subkeys_frozen
    assert_predicate build(subkeys: %w[a]).subkeys, :frozen?
  end
end
