# encoding: UTF-8

require "helper"

class TestInternals < Test::Unit::TestCase

  include Helper::Client

  def test_logger
    r.ping

    assert log.string =~ /Redis >> PING/
      assert log.string =~ /Redis >> \d+\.\d+ms/
  end

  def test_logger_with_pipelining
    r.pipelined do
      r.set "foo", "bar"
      r.get "foo"
    end

    assert log.string["SET foo bar"]
    assert log.string["GET foo"]
  end

  def test_recovers_from_failed_commands
    # See https://github.com/redis/redis-rb/issues#issue/28

    assert_raise(Redis::CommandError) do
      r.command_that_doesnt_exist
    end

    assert_nothing_raised do
      r.info
    end
  end

  def test_raises_on_protocol_errors
    redis_mock(:ping => lambda { |*_| "foo" }) do |redis|
      assert_raise(Redis::ProtocolError) do
        redis.ping
      end
    end
  end

  def test_provides_a_meaningful_inspect
    assert_equal "#<Redis client v#{Redis::VERSION} for redis://127.0.0.1:#{PORT}/15>", r.inspect
  end

  def test_redis_current
    assert_equal "127.0.0.1", Redis.current.client.host
    assert_equal 6379, Redis.current.client.port
    assert_equal 0, Redis.current.client.db

    Redis.current = Redis.new(OPTIONS.merge(:port => 6380, :db => 1))

    t = Thread.new do
      assert_equal "127.0.0.1", Redis.current.client.host
      assert_equal 6380, Redis.current.client.port
      assert_equal 1, Redis.current.client.db
    end

    t.join

    assert_equal "127.0.0.1", Redis.current.client.host
    assert_equal 6380, Redis.current.client.port
    assert_equal 1, Redis.current.client.db
  end

  def test_default_id_with_host_and_port
    redis = Redis.new(OPTIONS.merge(:host => "host", :port => "1234", :db => 0))
    assert_equal "redis://host:1234/0", redis.client.id
  end

  def test_default_id_with_host_and_port_and_explicit_scheme
    redis = Redis.new(OPTIONS.merge(:host => "host", :port => "1234", :db => 0, :scheme => "foo"))
    assert_equal "redis://host:1234/0", redis.client.id
  end

  def test_default_id_with_path
    redis = Redis.new(OPTIONS.merge(:path => "/tmp/redis.sock", :db => 0))
    assert_equal "redis:///tmp/redis.sock/0", redis.client.id
  end

  def test_default_id_with_path_and_explicit_scheme
    redis = Redis.new(OPTIONS.merge(:path => "/tmp/redis.sock", :db => 0, :scheme => "foo"))
    assert_equal "redis:///tmp/redis.sock/0", redis.client.id
  end

  def test_override_id
    redis = Redis.new(OPTIONS.merge(:id => "test"))
    assert_equal redis.client.id, "test"
  end

  def test_timeout
    assert_nothing_raised do
      Redis.new(OPTIONS.merge(:timeout => 0))
    end
  end

  def test_time
    return if version < "2.5.4"

    # Test that the difference between the time that Ruby reports and the time
    # that Redis reports is minimal (prevents the test from being racy).
    rv = r.time

    redis_usec = rv[0] * 1_000_000 + rv[1]
    ruby_usec = Integer(Time.now.to_f * 1_000_000)

    assert 500_000 > (ruby_usec - redis_usec).abs
  end

  def test_connection_timeout
    assert_raise Redis::CannotConnectError do
      Redis.new(OPTIONS.merge(:host => "10.255.255.254", :timeout => 0.1)).ping
    end
  end

  def test_retry_when_first_read_raises_econnreset
    $request = 0

    command = lambda do
      case ($request += 1)
      when 1; nil # Close on first command
      else "+%d" % $request
      end
    end

    redis_mock(:ping => command, :timeout => 0.1) do |redis|
      assert_equal "2", redis.ping
    end
  end

  def test_don_t_retry_when_wrapped_inside__without_reconnect
    $request = 0

    command = lambda do
      case ($request += 1)
      when 1; nil # Close on first command
      else "+%d" % $request
      end
    end

    redis_mock(:ping => command, :timeout => 0.1) do |redis|
      assert_raise Redis::ConnectionError do
        redis.without_reconnect do
          redis.ping
        end
      end

      assert !redis.client.connected?
    end
  end

  def test_retry_only_once_when_read_raises_econnreset
    $request = 0

    command = lambda do
      case ($request += 1)
      when 1; nil # Close on first command
      when 2; nil # Close on second command
      else "+%d" % $request
      end
    end

    redis_mock(:ping => command, :timeout => 0.1) do |redis|
      assert_raise Redis::ConnectionError do
        redis.ping
      end

      assert !redis.client.connected?
    end
  end

  def test_don_t_retry_when_second_read_in_pipeline_raises_econnreset
    $request = 0

    command = lambda do
      case ($request += 1)
      when 2; nil # Close on second command
      else "+%d" % $request
      end
    end

    redis_mock(:ping => command, :timeout => 0.1) do |redis|
      assert_raise Redis::ConnectionError do
        redis.pipelined do
          redis.ping
          redis.ping # Second #read times out
        end
      end
    end
  end

  def test_connecting_to_unix_domain_socket
    assert_nothing_raised do
      Redis.new(OPTIONS.merge(:path => "/tmp/redis.sock")).ping
    end
  end

  driver(:ruby, :hiredis) do
    def test_bubble_timeout_without_retrying
      serv = TCPServer.new(6380)

      redis = Redis.new(:port => 6380, :timeout => 0.1)

      assert_raise(Redis::TimeoutError) do
        redis.ping
      end

    ensure
      serv.close if serv
    end
  end
end
