# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestConnectionHandling < Test::Unit::TestCase

  include Helper::Client

  def test_auth
    commands = {
      :auth => lambda { |password| $auth = password; "+OK" },
      :get  => lambda { |key| $auth == "secret" ? "$3\r\nbar" : "$-1" },
    }

    redis_mock(commands, :password => "secret") do |redis|
      assert_equal "bar", redis.get("foo")
    end
  end

  def test_ping
    assert_equal "PONG", r.ping
  end

  def test_select
    r.set "foo", "bar"

    r.select 14
    assert_equal nil, r.get("foo")

    r.client.disconnect

    assert_equal nil, r.get("foo")
  end

  def test_quit
    r.quit

    assert !r.client.connected?
  end

  def test_shutdown
    commands = {
      :shutdown => lambda { :exit }
    }

    redis_mock(commands) do |redis|
      # SHUTDOWN does not reply: test that it does not raise here.
      assert_equal nil, redis.shutdown
    end
  end

  def test_shutdown_with_error
    connections = 0
    commands = {
      :select => lambda { |*_| connections += 1; "+OK\r\n" },
      :connections => lambda { ":#{connections}\r\n" },
      :shutdown => lambda { "-ERR could not shutdown\r\n" }
    }

    redis_mock(commands) do |redis|
      connections = redis.connections

      # SHUTDOWN replies with an error: test that it gets raised
      assert_raise Redis::CommandError do
        redis.shutdown
      end

      # The connection should remain in tact
      assert_equal connections, redis.connections
    end
  end

  def test_shutdown_from_pipeline
    commands = {
      :shutdown => lambda { :exit }
    }

    redis_mock(commands) do |redis|
      result = redis.pipelined do
        redis.shutdown
      end

      assert_equal nil, result
      assert !redis.client.connected?
    end
  end

  def test_shutdown_with_error_from_pipeline
    connections = 0
    commands = {
      :select => lambda { |*_| connections += 1; "+OK\r\n" },
      :connections => lambda { ":#{connections}\r\n" },
      :shutdown => lambda { "-ERR could not shutdown\r\n" }
    }

    redis_mock(commands) do |redis|
      connections = redis.connections

      # SHUTDOWN replies with an error: test that it gets raised
      assert_raise Redis::CommandError do
        redis.pipelined do
          redis.shutdown
        end
      end

      # The connection should remain in tact
      assert_equal connections, redis.connections
    end
  end

  def test_shutdown_from_multi_exec
    commands = {
      :multi => lambda { "+OK\r\n" },
      :shutdown => lambda { "+QUEUED\r\n" },
      :exec => lambda { :exit }
    }

    redis_mock(commands) do |redis|
      result = redis.multi do
        redis.shutdown
      end

      assert_equal nil, result
      assert !redis.client.connected?
    end
  end

  def test_shutdown_with_error_from_multi_exec
    connections = 0
    commands = {
      :select => lambda { |*_| connections += 1; "+OK\r\n" },
      :connections => lambda { ":#{connections}\r\n" },
      :multi => lambda { "+OK\r\n" },
      :shutdown => lambda { "+QUEUED\r\n" },
      :exec => lambda { "*1\r\n-ERR could not shutdown\r\n" }
    }

    redis_mock(commands) do |redis|
      connections = redis.connections

      # SHUTDOWN replies with an error: test that it gets returned
      # We should test for Redis::CommandError here, but hiredis doesn't yet do
      # custom error classes.
      err = nil

      begin
        redis.multi { redis.shutdown }
      rescue => err
      end

      assert err.kind_of?(StandardError)

      # The connection should remain intact
      assert_equal connections, redis.connections
    end
  end

  def test_slaveof
    redis_mock(:slaveof => lambda { |host, port| "+SLAVEOF #{host} #{port}" }) do |redis|
      assert_equal "SLAVEOF somehost 6381", redis.slaveof("somehost", 6381)
    end
  end

  def test_bgrewriteaof
    redis_mock(:bgrewriteaof => lambda { "+BGREWRITEAOF" }) do |redis|
      assert_equal "BGREWRITEAOF", redis.bgrewriteaof
    end
  end

  def test_config_get
    assert r.config(:get, "*")["timeout"] != nil

    config = r.config(:get, "timeout")
    assert_equal ["timeout"], config.keys
    assert config.values.compact.size > 0
  end

  def test_config_set
    begin
      assert_equal "OK", r.config(:set, "timeout", 200)
      assert_equal "200", r.config(:get, "*")["timeout"]

      assert_equal "OK", r.config(:set, "timeout", 100)
      assert_equal "100", r.config(:get, "*")["timeout"]
    ensure
      r.config :set, "timeout", 300
    end
  end
end
