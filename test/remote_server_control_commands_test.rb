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
    # Only available on Redis >= 2.9.0
    return if version < 209000

    r.config(:resetstat)
    r.ping

    result = r.info(:commandstats)
    assert "1" == result["ping"]["calls"]
  end

  def test_monitor__redis_________
    return unless version < 205000

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

  def test_monitor__redis__________
    return unless version >= 205000

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

    assert result == "OK"
  end

  def test_echo
    assert "foo bar baz\n" == r.echo("foo bar baz\n")
  end

  def test_debug
    r.set "foo", "s1"

    assert r.debug(:object, "foo").kind_of?(String)
  end

  def test_object
    r.lpush "list", "value"

    assert r.object(:refcount, "list") == 1
    assert r.object(:encoding, "list") == "ziplist"
    assert r.object(:idletime, "list").kind_of?(Fixnum)
  end

  def test_sync
    replies = {:sync => lambda { "+OK" }}

    redis_mock(replies) do
      redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

      assert "OK" == redis.sync
    end
  end

  def test_slowlog
    r.slowlog(:reset)
    result = r.slowlog(:len)
    assert result == 0
  end
end
