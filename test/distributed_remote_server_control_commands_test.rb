# encoding: UTF-8

require "helper"

class TestDistributedRemoteServerControlCommands < Test::Unit::TestCase

  include Helper::Distributed

  def test_info
    keys = [
     "redis_version",
     "uptime_in_seconds",
     "uptime_in_days",
     "connected_clients",
     "used_memory",
     "total_connections_received",
     "total_commands_processed",
    ]

    info = r.info

    info.each do |info|
      keys.each do |k|
        msg = "expected #info to include #{k}"
        assert info.keys.include?(k), msg
      end
    end
  end

  def test_info_commandstats
    return if version < "2.5.7"

    r.nodes.each { |n| n.config(:resetstat) }
    r.ping # Executed on every node

    r.info(:commandstats).each do |info|
      assert_equal "1", info["ping"]["calls"]
    end
  end

  def test_monitor
    begin
      r.monitor
    rescue Exception => ex
    ensure
      assert ex.kind_of?(NotImplementedError)
    end
  end

  def test_echo
    assert_equal ["foo bar baz\n"], r.echo("foo bar baz\n")
  end

  def test_time
    return if version < "2.5.4"

    # Test that the difference between the time that Ruby reports and the time
    # that Redis reports is minimal (prevents the test from being racy).
    r.time.each do |rv|
      redis_usec = rv[0] * 1_000_000 + rv[1]
      ruby_usec = Integer(Time.now.to_f * 1_000_000)

      assert 500_000 > (ruby_usec - redis_usec).abs
    end
  end

  def test_client_list
    return if version < "2.4.0"

    keys = [
     "addr",
     "fd",
     "name",
     "age",
     "idle",
     "flags",
     "db",
     "sub",
     "psub",
     "multi",
     "qbuf",
     "qbuf-free",
     "obl",
     "oll",
     "omem",
     "events",
     "cmd"
    ]

    clients = r.client(:list).first
    clients.each do |client|
      keys.each do |k|
        msg = "expected #client(:list) to include #{k}"
        assert client.keys.include?(k), msg
      end
    end
  end

  def test_client_kill
    return if version < "2.6.9"

    r.client(:setname, 'redis-rb')
    clients = r.client(:list).first
    i = clients.index {|client| client['name'] == 'redis-rb'}
    assert_equal ["OK"], r.client(:kill, clients[i]["addr"])

    clients = r.client(:list).first
    i = clients.index {|client| client['name'] == 'redis-rb'}
    assert_equal nil, i
  end

  def test_client_getname_and_setname
    return if version < "2.6.9"

    assert_equal [nil], r.client(:getname)

    r.client(:setname, 'redis-rb')
    names = r.client(:getname)
    assert_equal ['redis-rb'], names
  end
end
