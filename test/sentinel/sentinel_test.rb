# frozen_string_literal: true

require "helper"

class SentinelTest < Minitest::Test
  include Helper::Sentinel

  def test_sentinel_master_role_connection
    wait_for_quorum

    actual = redis.role

    assert_equal 'master', actual[0]
  end

  def test_sentinel_slave_role_connection
    wait_for_quorum

    redis = build_slave_role_client
    actual = redis.role

    assert_equal 'slave', actual[0]
    assert_equal MASTER_PORT.to_i, actual[2]
  end

  def test_without_reconnect
    wait_for_quorum

    redis.without_reconnect do
      redis.get("key")
    end
  end

  def test_the_client_can_connect_to_available_slaves
    commands = {
      sentinel: lambda do |*_|
        [
          ['ip', '127.0.0.1', 'port', '6382', 'flags', 'slave'],
          ['ip', '127.0.0.1', 'port', '6383', 'flags', 's_down,slave,disconnected']
        ]
      end
    }
    RedisMock.start(commands) do |port|
      redis = build_slave_role_client(sentinels: [{ host: '127.0.0.1', port: port }])
      assert_equal 'PONG', redis.ping
    end
  end

  def test_the_client_raises_error_when_there_is_no_available_slaves
    commands = {
      sentinel: lambda do |*_|
        [
          ['ip', '127.0.0.1', 'port', '6382', 'flags', 's_down,slave,disconnected'],
          ['ip', '127.0.0.1', 'port', '6383', 'flags', 's_down,slave,disconnected']
        ]
      end
    }
    RedisMock.start(commands) do |port|
      redis = build_slave_role_client(sentinels: [{ host: '127.0.0.1', port: port }])
      assert_raises(Redis::CannotConnectError) { redis.ping }
    end
  end

  def test_sentinel_failover
    sentinels = [{ host: "127.0.0.1", port: 26_381 },
                 { host: "127.0.0.1", port: 26_382 }]

    commands = {
      s1: [],
      s2: []
    }

    s1 = {
      sentinel: lambda do |command, *args|
        commands[:s1] << [command, *args]
        "$-1" # Nil
      end
    }

    s2 = {
      sentinel: lambda do |command, *args|
        commands[:s2] << [command, *args]
        case command
        when "get-master-addr-by-name"
          ["127.0.0.1", "6381"]
        when "sentinels"
          []
        else
          raise "Unexpected command #{[command, *args].inspect}"
        end
      end
    }

    RedisMock.start(s1) do |s1_port|
      RedisMock.start(s2) do |s2_port|
        sentinels[0][:port] = s1_port
        sentinels[1][:port] = s2_port
        redis = Redis.new(url: "redis://master1", sentinels: sentinels, role: :master)

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], [%w[get-master-addr-by-name master1], ["sentinels", "master1"]]
  end

  def test_sentinel_failover_prioritize_healthy_sentinel
    sentinels = [{ host: "127.0.0.1", port: 26_381 },
                 { host: "127.0.0.1", port: 26_382 }]

    commands = {
      s1: [],
      s2: []
    }

    s1 = {
      sentinel: lambda do |command, *args|
        commands[:s1] << [command, *args]
        "$-1" # Nil
      end
    }

    s2 = {
      sentinel: lambda do |command, *args|
        commands[:s2] << [command, *args]
        case command
        when "get-master-addr-by-name"
          ["127.0.0.1", "6381"]
        when "sentinels"
          [
            ["ip", "127.0.0.1", "port", "26381"],
            ["ip", "127.0.0.1", "port", "26382"],
          ]
        else
          raise "Unexpected command #{[command, *args].inspect}"
        end
      end
    }

    RedisMock.start(s1) do |s1_port|
      RedisMock.start(s2) do |s2_port|
        sentinels[0][:port] = s1_port
        sentinels[1][:port] = s2_port
        redis = Redis.new(url: "redis://master1", sentinels: sentinels, role: :master)

        assert redis.ping

        redis.quit

        assert redis.ping
      end
    end

    assert_equal [%w[get-master-addr-by-name master1]], commands[:s1]
    assert_equal [%w[get-master-addr-by-name master1],  ["sentinels", "master1"]], commands[:s2]
  end

  def test_sentinel_with_non_sentinel_options
    commands = { s1: [], m1: [] }

    sentinel = lambda do |port|
      {
        auth: lambda do |*args|
          commands[:s1] << ['auth', *args]
          '+OK'
        end,
        select: lambda do |db|
          commands[:s1] << ['select', db]
          "-ERR unknown command 'select'"
        end,
        sentinel: lambda do |command, *args|
          commands[:s1] << [command, *args]
          case command
          when "get-master-addr-by-name"
            ["127.0.0.1", port.to_s]
          when "sentinels"
            [
              ["ip", "127.0.0.1", "port", "26381"],
              ["ip", "127.0.0.1", "port", "26382"],
            ]
          else
            raise "Unexpected command #{[command, *args].inspect}"
          end
        end
      }
    end

    master = {
      auth: lambda do |*args|
        commands[:m1] << ['auth', *args]
        '+OK'
      end,
      role: lambda do
        commands[:m1] << ['role']
        ['master']
      end
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(sentinel.call(master_port)) do |sen_port|
        s = [{ host: '127.0.0.1', port: sen_port }]
        redis = Redis.new(url: 'redis://:foo@master1/15', sentinels: s, role: :master)
        assert redis.ping
      end
    end

    assert_equal [%w[auth foo], %w[get-master-addr-by-name master1], ["sentinels", "master1"]], commands[:s1]
    assert_equal [%w[auth foo], %w[role]], commands[:m1]
  end

  def test_authentication_for_sentinel
    commands = { s1: [], m1: [] }

    sentinel = lambda do |port|
      {
        auth: lambda do |*args|
          commands[:s1] << ['auth', *args]
          '+OK'
        end,
        select: lambda do |db|
          commands[:s1] << ['select', db]
          '-ERR unknown command `select`'
        end,
        sentinel: lambda do |command, *args|
          commands[:s1] << [command, *args]
          case command
          when "get-master-addr-by-name"
            ["127.0.0.1", port.to_s]
          when "sentinels"
            [
              ["ip", "127.0.0.1", "port", "26381"],
              ["ip", "127.0.0.1", "port", "26382"],
            ]
          else
            raise "Unexpected command #{[command, *args].inspect}"
          end
        end
      }
    end

    master = {
      auth: lambda do |*args|
        commands[:s1] << ['auth', *args]
        '-ERR Client sent AUTH, but no password is set'
      end,
      role: lambda do
        commands[:m1] << ['role']
        ['master']
      end
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(sentinel.call(master_port)) do |sen_port|
        s = [{ host: '127.0.0.1', port: sen_port }]
        r = Redis.new(name: 'master1', sentinels: s, role: :master, sentinel_password: 'foo')
        assert r.ping
      end
    end

    assert_equal [%w[auth foo], %w[get-master-addr-by-name master1], ["sentinels", "master1"]], commands[:s1]
    assert_equal [%w[role]], commands[:m1]
  end

  def test_authentication_for_sentinel_and_redis
    commands = { s1: [], m1: [] }

    sentinel = lambda do |port|
      {
        auth: lambda do |*args|
          commands[:s1] << ['auth', *args]
          '+OK'
        end,
        select: lambda do |db|
          commands[:s1] << ['select', db]
          '-ERR unknown command `select`'
        end,
        sentinel: lambda do |command, *args|
          commands[:s1] << [command, *args]
          case command
          when "get-master-addr-by-name"
            ["127.0.0.1", port.to_s]
          when "sentinels"
            [
              ["ip", "127.0.0.1", "port", "26381"],
              ["ip", "127.0.0.1", "port", "26382"],
            ]
          else
            raise "Unexpected command #{[command, *args].inspect}"
          end
        end,
      }
    end

    master = {
      auth: lambda do |*args|
        commands[:m1] << ['auth', *args]
        '+OK'
      end,
      role: lambda do
        commands[:m1] << ['role']
        ['master']
      end,
      sentinel: lambda do |command, *args|
        commands[:s2] << [command, *args]
      end,
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(sentinel.call(master_port)) do |sen_port|
        s = [{ host: '127.0.0.1', port: sen_port }]
        r = Redis.new(name: 'master1', sentinels: s, role: :master, password: 'bar', sentinel_password: 'foo')
        assert r.ping
      end
    end

    assert_equal [%w[auth foo], %w[get-master-addr-by-name master1], ["sentinels", "master1"]], commands[:s1]
    assert_equal [%w[auth bar], %w[role]], commands[:m1]
  end

  def test_authentication_with_acl
    commands = { s1: [], m1: [] }

    sentinel = lambda do |port|
      {
        auth: lambda do |user, pass|
          commands[:s1] << ['auth', user, pass]
          '+OK'
        end,
        select: lambda do |db|
          commands[:s1] << ['select', db]
          '-ERR unknown command `select`'
        end,
        sentinel: lambda do |command, *args|
          commands[:s1] << [command, *args]
          case command
          when "get-master-addr-by-name"
            ["127.0.0.1", port.to_s]
          when "sentinels"
            [
              ["ip", "127.0.0.1", "port", "26381"],
              ["ip", "127.0.0.1", "port", "26382"],
            ]
          else
            raise "Unexpected command #{[command, *args].inspect}"
          end
        end
      }
    end

    master = {
      auth: lambda do |user, pass|
        commands[:m1] << ['auth', user, pass]
        '+OK'
      end,
      role: lambda do
        commands[:m1] << ['role']
        ['master']
      end
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(sentinel.call(master_port)) do |sen_port|
        s = [{ host: '127.0.0.1', port: sen_port }]
        r = Redis.new(name: 'master1', sentinels: s, role: :master, username: 'alice', password: 'bar', sentinel_username: 'bob', sentinel_password: 'foo')
        assert r.ping
      end
    end

    assert_equal [%w[auth bob foo], %w[get-master-addr-by-name master1], ["sentinels", "master1"]], commands[:s1]
    assert_equal [%w[auth alice bar], %w[role]], commands[:m1]
  end

  def test_sentinel_role_mismatch
    sentinels = [{ host: "127.0.0.1", port: 26_381 }]

    sentinel = lambda do |port|
      {
        sentinel: lambda do |command, *_args|
          case command
          when "get-master-addr-by-name"
            ["127.0.0.1", port.to_s]
          when "sentinels"
            [
              ["ip", "127.0.0.1", "port", "26381"],
            ]
          else
            raise "Unexpected command #{[command, *args].inspect}"
          end
        end
      }
    end

    master = {
      role: lambda do
        ["slave"]
      end
    }

    ex = assert_raises(Redis::CannotConnectError) do
      RedisMock.start(master) do |master_port|
        RedisMock.start(sentinel.call(master_port)) do |sen_port|
          sentinels[0][:port] = sen_port
          redis = Redis.new(url: "redis://master1", sentinels: sentinels, role: :master, reconnect_attempts: 0)

          assert redis.ping
        end
      end
    end

    assert_match(/Expected to connect to a master, but the server is a replica/, ex.message)
  end

  def test_sentinel_retries
    sentinels = [{ host: "127.0.0.1", port: 26_381 },
                 { host: "127.0.0.1", port: 26_382 }]

    connections = []

    fails = Hash.new(0)

    handler = lambda do |id, port|
      {
        sentinel: lambda do |command, *_args|
          connections << id

          if fails[id] < 2
            fails[id] += 1
            :close
          else
            case command
            when "get-master-addr-by-name"
              ["127.0.0.1", port.to_s]
            when "sentinels"
              [
                ["ip", "127.0.0.1", "port", "26381"],
                ["ip", "127.0.0.1", "port", "26382"],
              ]
            else
              raise "Unexpected command #{[command, *args].inspect}"
            end
          end
        end
      }
    end

    master = {
      role: lambda do
        ["master"]
      end
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(handler.call(:s1, master_port)) do |s1_port|
        RedisMock.start(handler.call(:s2, master_port)) do |s2_port|
          sentinels[0][:port] = s1_port
          sentinels[1][:port] = s2_port
          redis = Redis.new(url: "redis://master1", sentinels: sentinels, role: :master, reconnect_attempts: 1)

          assert redis.ping
        end
      end
    end

    assert_equal %i[s1 s1 s2 s2 s1 s1], connections

    connections.clear
    fails.clear

    ex = assert_raises(Redis::CannotConnectError) do
      RedisMock.start(master) do |master_port|
        RedisMock.start(handler.call(:s1, master_port)) do |s1_port|
          RedisMock.start(handler.call(:s2, master_port)) do |s2_port|
            sentinels[0][:port] = s1_port + 1
            sentinels[1][:port] = s2_port + 2
            redis = Redis.new(url: "redis://master1", sentinels: sentinels, role: :master, reconnect_attempts: 0)

            assert redis.ping
          end
        end
      end
    end

    assert_match(/No sentinels available/, ex.message)
  end
end
