# frozen_string_literal: true

require "helper"

class TestRemoteServerControlCommands < Minitest::Test
  include Helper::Client

  def test_info
    keys = [
      "redis_version",
      "uptime_in_seconds",
      "uptime_in_days",
      "connected_clients",
      "used_memory",
      "total_connections_received",
      "total_commands_processed"
    ]

    info = r.info

    keys.each do |k|
      msg = "expected #info to include #{k}"
      assert info.keys.include?(k), msg
    end
  end

  def test_info_commandstats
    r.config(:resetstat)
    r.get("foo")
    r.get("bar")

    result = r.info(:commandstats)
    assert_equal '2', result['get']['calls']
  end

  def test_waitaof
    target_version "7.2.0" do
      r.set("foo", "bar")

      local, replicas = r.waitaof(0, 0, 0)

      assert_equal 0, local
      assert_kind_of Integer, replicas
    end
  end

  def test_waitaof_with_local_fsync
    target_version "7.2.0" do
      original = r.config(:get, "appendonly")["appendonly"]
      begin
        r.config(:set, "appendonly", "yes")
        r.set("foo", "bar")

        assert_equal 1, r.waitaof(1, 0, 5000).first
      ensure
        r.config(:set, "appendonly", original)
      end
    end
  end

  def test_waitaof_with_numlocal_when_aof_is_disabled
    target_version "7.2.0" do
      original = r.config(:get, "appendonly")["appendonly"]
      begin
        r.config(:set, "appendonly", "no")

        error = assert_raises(Redis::CommandError) { r.waitaof(1, 0, 0) }
        assert_match(/appendonly is disabled/, error.message)
      ensure
        r.config(:set, "appendonly", original)
      end
    end
  end

  def test_waitaof_returns_when_the_timeout_expires
    target_version "7.2.0" do
      r.set("foo", "bar")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # Nobody has 100 replicas, so this can only return via the 100ms timeout.
      local, replicas = r.waitaof(0, 100, 100)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 0, local
      assert_kind_of Integer, replicas
      assert_operator elapsed, :<, 2
    end
  end

  def test_waitaof_sends_the_arguments_in_order
    received = nil
    commands = { waitaof: ->(*args) { received = args; "*2\r\n:1\r\n:0\r\n" } }

    redis_mock(commands) do |redis|
      assert_equal [1, 0], redis.waitaof(0, 1, 1000)
    end

    assert_equal %w[0 1 1000], received
  end

  def test_waitaof_in_pipeline
    target_version "7.2.0" do
      r.set("foo", "bar")

      result = r.pipelined do |pipe|
        pipe.waitaof(0, 0, 0)
      end

      local, replicas = result.first
      assert_equal 0, local
      assert_kind_of Integer, replicas
    end
  end

  def test_monitor_redis
    log = []

    thread = Thread.new do
      Redis.new(OPTIONS).monitor do |line|
        log << line
        break if line =~ /set/
      end
    end

    Thread.pass while log.empty? # Faster than sleep

    r.set "foo", "s1"

    thread.join

    assert log[-1] =~ /\b15\b.* "set" "foo" "s1"/
  end

  def test_monitor_returns_value_for_break
    result = r.monitor do |line|
      break line
    end

    assert_equal "OK", result
  end

  def test_echo
    assert_equal "foo bar baz\n", r.echo("foo bar baz\n")
  end

  def test_debug
    r.set "foo", "s1"

    assert r.debug(:object, "foo").is_a?(String)
  end

  def test_object
    r.lpush "list", "value"

    assert_equal 1, r.object(:refcount, "list")
    encoding = r.object(:encoding, "list")
    assert encoding == "ziplist" || encoding == "quicklist" || encoding == "listpack", "Wrong encoding for list"
    assert r.object(:idletime, "list").is_a?(Integer)
  end

  def test_sync
    redis_mock(sync: -> { "+OK" }) do |redis|
      assert_equal "OK", redis.sync
    end
  end

  def test_slowlog
    r.slowlog(:reset)
    result = r.slowlog(:len)
    assert_equal 0, result
  end

  def test_client
    assert_equal r.instance_variable_get(:@client), r._client
  end

  def test_client_list
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

    clients = r.client(:list)
    clients.each do |client|
      keys.each do |k|
        msg = "expected #client(:list) to include #{k}"
        assert client.keys.include?(k), msg
      end
    end
  end

  def test_client_kill
    r.client(:setname, 'redis-rb')
    clients = r.client(:list)
    i = clients.index { |client| client['name'] == 'redis-rb' }
    assert_equal "OK", r.client(:kill, clients[i]["addr"])

    clients = r.client(:list)
    i = clients.index { |client| client['name'] == 'redis-rb' }
    assert_nil i
  end

  def test_client_getname_and_setname
    assert_nil r.client(:getname)

    r.client(:setname, 'redis-rb')
    name = r.client(:getname)
    assert_equal 'redis-rb', name
  end
end
