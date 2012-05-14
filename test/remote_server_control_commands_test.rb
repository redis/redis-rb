# encoding: UTF-8

require "helper"

class TestRemoteServerControlCommands < Test::Unit::TestCase

  include Helper

  def test_info
    %w(last_save_time redis_version total_connections_received connected_clients total_commands_processed connected_slaves uptime_in_seconds used_memory uptime_in_days changes_since_last_save).each do |x|
      assert r.info.keys.include?(x)
    end
  end

  def test_info_commandstats
    return if version < "2.9.0"

    r.config(:resetstat)
    r.ping

    result = r.info(:commandstats)
    assert_equal "1", result["ping"]["calls"]
  end

  def test_monitor_redis_lt_2_5_0
    return unless version < "2.5.0"

    log = []

    wire = Wire.new do
      Redis.new(OPTIONS).monitor do |line|
        log << line
        break if log.size == 3
      end
    end

    Wire.pass while log.empty? # Faster than sleep

    r.set "foo", "s1"

    wire.join

    assert log[-1][%q{(db 15) "set" "foo" "s1"}]
  end

  def test_monitor_redis_gte_2_5_0
    return unless version >= "2.5.0"

    log = []

    wire = Wire.new do
      Redis.new(OPTIONS).monitor do |line|
        log << line
        break if line =~ /set/
      end
    end

    Wire.pass while log.empty? # Faster than sleep

    r.set "foo", "s1"

    wire.join

    assert log[-1] =~ /\b15\b.* "set" "foo" "s1"/
  end

  def test_monitor_returns_value_for_break
    result = r.monitor do |line|
      break line
    end

    assert_equal result, "OK"
  end

  def test_echo
    assert_equal "foo bar baz\n", r.echo("foo bar baz\n")
  end

  def test_debug
    r.set "foo", "s1"

    assert r.debug(:object, "foo").kind_of?(String)
  end

  def test_object
    r.lpush "list", "value"

    assert_equal r.object(:refcount, "list"), 1
    assert_equal r.object(:encoding, "list"), "ziplist"
    assert r.object(:idletime, "list").kind_of?(Fixnum)
  end

  def test_sync
    replies = {:sync => lambda { "+OK" }}

    redis_mock(replies) do |redis|
      assert_equal "OK", redis.sync
    end
  end

  def test_slowlog
    r.slowlog(:reset)
    result = r.slowlog(:len)
    assert_equal result, 0
  end
end
