# frozen_string_literal: true

require "helper"
require 'lint/authentication'

class TestConnectionHandling < Minitest::Test
  include Helper::Client
  include Lint::Authentication

  def test_id
    commands = {
      client: ->(cmd, name) { @name = [cmd, name]; "+OK" },
      ping: -> { "+PONG" }
    }

    redis_mock(commands, id: "client-name") do |redis|
      assert_equal "PONG", redis.ping
    end

    assert_equal ["SETNAME", "client-name"], @name
  end

  def test_ping
    assert_equal "PONG", r.ping
  end

  def test_select
    r.set "foo", "bar"

    r.select 14
    assert_nil r.get("foo")

    r._client.close

    assert_equal "bar", r.get("foo")
  end

  def test_quit
    r.quit

    assert !r._client.connected?
  end

  def test_close
    quit = 0

    commands = {
      quit: lambda do
        quit += 1
        "+OK"
      end
    }

    redis_mock(commands) do |redis|
      assert_equal 0, quit

      redis.quit

      assert_equal 1, quit

      redis.ping

      redis.close

      assert_equal 1, quit

      assert !redis.connected?
    end
  end

  def test_disconnect
    quit = 0

    commands = {
      quit: lambda do
        quit += 1
        "+OK"
      end
    }

    redis_mock(commands) do |redis|
      assert_equal 0, quit

      redis.quit

      assert_equal 1, quit

      redis.ping

      redis.disconnect!

      assert_equal 1, quit

      assert !redis.connected?
    end
  end

  def test_shutdown
    commands = {
      shutdown: -> { :exit }
    }

    redis_mock(commands) do |redis|
      # SHUTDOWN does not reply: test that it does not raise here.
      assert_nil redis.shutdown
    end
  end

  def test_shutdown_with_error
    connections = 0
    commands = {
      select: ->(*_) { connections += 1; "+OK\r\n" },
      connections: -> { ":#{connections}\r\n" },
      shutdown: -> { "-ERR could not shutdown\r\n" }
    }

    redis_mock(commands) do |redis|
      connections = redis.connections

      # SHUTDOWN replies with an error: test that it gets raised
      assert_raises Redis::CommandError do
        redis.shutdown
      end

      # The connection should remain in tact
      assert_equal connections, redis.connections
    end
  end

  def test_slaveof
    redis_mock(slaveof: ->(host, port) { "+SLAVEOF #{host} #{port}" }) do |redis|
      assert_equal "SLAVEOF somehost 6381", redis.slaveof("somehost", 6381)
    end
  end

  def test_bgrewriteaof
    redis_mock(bgrewriteaof: -> { "+BGREWRITEAOF" }) do |redis|
      assert_equal "BGREWRITEAOF", redis.bgrewriteaof
    end
  end

  def test_config_get
    refute_nil r.config(:get, "*")["timeout"]

    config = r.config(:get, "timeout")
    assert_equal ["timeout"], config.keys
    assert !config.values.compact.empty?
  end
  g
  def test_config_set
    assert_equal "OK", r.config(:set, "timeout", 200)
    assert_equal "200", r.config(:get, "*")["timeout"]

    assert_equal "OK", r.config(:set, "timeout", 100)
    assert_equal "100", r.config(:get, "*")["timeout"]
  ensure
    r.config :set, "timeout", 300
  end
end
