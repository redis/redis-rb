# encoding: UTF-8

require "helper"

class TestInternals < Test::Unit::TestCase

  include Helper

  attr_reader :log

  def setup
    @log = StringIO.new
    @r = init Redis.new(OPTIONS.merge(:logger => ::Logger.new(log)))
  end

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
    redis_mock(:ping => lambda { |*_| "foo" }) do
      assert_raise(Redis::ProtocolError) do
        Redis.connect(:port => MOCK_PORT).ping
      end
    end
  end

  def test_provides_a_meaningful_inspect
    assert "#<Redis client v#{Redis::VERSION} for redis://127.0.0.1:#{PORT}/15>" == r.inspect
  end

  def test_redis_current
    assert "127.0.0.1" == Redis.current.client.host
    assert 6379 == Redis.current.client.port
    assert 0 == Redis.current.client.db

    Redis.current = Redis.new(OPTIONS.merge(:port => 6380, :db => 1))

    t = Thread.new do
      assert "127.0.0.1" == Redis.current.client.host
      assert 6380 == Redis.current.client.port
      assert 1 == Redis.current.client.db
    end

    t.join

    assert "127.0.0.1" == Redis.current.client.host
    assert 6380 == Redis.current.client.port
    assert 1 == Redis.current.client.db
  end

  def test_timeout
    assert_nothing_raised do
      Redis.new(OPTIONS.merge(:timeout => 0))
    end
  end

  def test_time
    return if version(r) < 205040

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

    redis_mock(:ping => command) do
      redis = Redis.connect(:port => MOCK_PORT, :timeout => 0.1)
      assert "2" == redis.ping
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

    redis_mock(:ping => command) do
      redis = Redis.connect(:port => MOCK_PORT, :timeout => 0.1)
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

    redis_mock(:ping => command) do
      redis = Redis.connect(:port => MOCK_PORT, :timeout => 0.1)
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

    redis_mock(:ping => command) do
      redis = Redis.connect(:port => MOCK_PORT, :timeout => 0.1)
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
    # Using a mock server in a thread doesn't work here (possibly because blocking
    # socket ops, raw socket timeouts and Ruby's thread scheduling don't mix).
    def test_bubble_eagain_without_retrying
      cmd = %{(sleep 0.3; echo "+PONG\r\n") | nc -l 6380}
      IO.popen(cmd) do |_|
        sleep 0.1 # Give nc a little time to start listening
        redis = Redis.connect(:port => 6380, :timeout => 0.1)

        begin
          assert_raise(Redis::TimeoutError) { redis.ping }
        ensure
          # Explicitly close connection so nc can quit
          redis.client.disconnect
        end
      end
    end
  end
end
