# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class SentinalTest < Test::Unit::TestCase

  include Helper::Client

  def test_sentinel_connection
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    handler = lambda do |id|
      {
        :sentinel => lambda do |command, *args|
          commands[id] << [command, *args]
          ["127.0.0.1", "6381"]
        end
      }
    end

    RedisMock.start(handler.call(:s1), {}, 26381) do
      RedisMock.start(handler.call(:s2), {}, 26382) do
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], []
  end

  def test_sentinel_failover
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    s1 = {
      :sentinel => lambda do |command, *args|
        commands[:s1] << [command, *args]
        "$-1" # Nil
      end
    }

    s2 = {
      :sentinel => lambda do |command, *args|
        commands[:s2] << [command, *args]
        ["127.0.0.1", "6381"]
      end
    }

    RedisMock.start(s1, {}, 26381) do
      RedisMock.start(s2, {}, 26382) do
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], [%w[get-master-addr-by-name master1]]
  end

  def test_sentinel_failover_prioritize_healthy_sentinel
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    s1 = {
      :sentinel => lambda do |command, *args|
        commands[:s1] << [command, *args]
        "$-1" # Nil
      end
    }

    s2 = {
      :sentinel => lambda do |command, *args|
        commands[:s2] << [command, *args]
        ["127.0.0.1", "6381"]
      end
    }

    RedisMock.start(s1, {}, 26381) do
      RedisMock.start(s2, {}, 26382) do
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping

        redis.quit

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], [%w[get-master-addr-by-name master1], %w[get-master-addr-by-name master1]]
  end

  def test_sentinel_with_non_sentinel_options
    sentinels = [{:host => "127.0.0.1", :port => 26381}]

    commands = {
      :s1 => [],
      :m1 => []
    }

    sentinel = {
      :auth => lambda do |pass|
        commands[:s1] << ["auth", pass]
        "-ERR unknown command 'auth'"
      end,
      :select => lambda do |db|
        commands[:s1] << ["select", db]
        "-ERR unknown command 'select'"
      end,
      :sentinel => lambda do |command, *args|
        commands[:s1] << [command, *args]
        ["127.0.0.1", "6382"]
      end
    }

    master = {
      :auth => lambda do |pass|
        commands[:m1] << ["auth", pass]
        "+OK"
      end,
      :role => lambda do
        commands[:m1] << ["role"]
        ["master"]
      end
    }

    RedisMock.start(master, {}, 6382) do
      RedisMock.start(sentinel, {}, 26381) do
        redis = Redis.new(:url => "redis://:foo@master1/15", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal [%w[get-master-addr-by-name master1]], commands[:s1]
    assert_equal [%w[auth foo], %w[role]], commands[:m1]
  end

  def test_sentinel_role_mismatch
    sentinels = [{:host => "127.0.0.1", :port => 26381}]

    sentinel = {
      :sentinel => lambda do |command, *args|
        ["127.0.0.1", "6382"]
      end
    }

    master = {
      :role => lambda do
        ["slave"]
      end
    }

    ex = assert_raise(Redis::ConnectionError) do
      RedisMock.start(master, {}, 6382) do
        RedisMock.start(sentinel, {}, 26381) do
          redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

          assert redis.ping
        end
      end
    end

    assert_match(/Instance role mismatch/, ex.message)
  end

  def test_sentinel_retries
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    connections = []

    handler = lambda do |id|
      {
        :sentinel => lambda do |command, *args|
          connections << id

          if connections.count(id) < 2
            :close
          else
            ["127.0.0.1", "6382"]
          end
        end
      }
    end

    master = {
      :role => lambda do
        ["master"]
      end
    }

    RedisMock.start(master, {}, 6382) do
      RedisMock.start(handler.call(:s1), {}, 26381) do
        RedisMock.start(handler.call(:s2), {}, 26382) do
          redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master, :reconnect_attempts => 1)

          assert redis.ping
        end
      end
    end

    assert_equal [:s1, :s2, :s1], connections

    connections.clear

    ex = assert_raise(Redis::CannotConnectError) do
      RedisMock.start(master, {}, 6382) do
        RedisMock.start(handler.call(:s1), {}, 26381) do
          RedisMock.start(handler.call(:s2), {}, 26382) do
            redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master, :reconnect_attempts => 0)

            assert redis.ping
          end
        end
      end
    end

    assert_match(/No sentinels available/, ex.message)
  end
end
