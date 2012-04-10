# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

setup do
  log = StringIO.new

  [Redis.new(OPTIONS.merge(:logger => ::Logger.new(log))), log]
end

$TEST_PIPELINING = true

load File.expand_path("./lint/internals.rb", File.dirname(__FILE__))

test "provides a meaningful inspect" do |r, _|
  assert "#<Redis client v#{Redis::VERSION} connected to redis://127.0.0.1:#{PORT}/15 (Redis v#{r.info["redis_version"]})>" == r.inspect
end

test "Redis.current" do |r, _|
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

test "Timeout" do
  assert_nothing_raised do
    Redis.new(OPTIONS.merge(:timeout => 0))
  end
end

test "Time" do |r,_|
  next if version(r) < 205040

  assert Time.now.to_i.to_s == r.time.first
end

test "Connection timeout" do
  next if driver == :synchrony

  assert_raise Redis::CannotConnectError do
    Redis.new(OPTIONS.merge(:host => "10.255.255.254", :timeout => 0.1)).ping
  end
end

test "Retry when first read raises ECONNRESET" do
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

test "Don't retry when wrapped inside #without_reconnect" do
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

test "Retry only once when read raises ECONNRESET" do
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

test "Don't retry when second read in pipeline raises ECONNRESET" do
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

test "Connecting to UNIX domain socket" do
  assert_nothing_raised do
    Redis.new(OPTIONS.merge(:path => "/tmp/redis.sock")).ping
  end
end

if driver == :ruby || driver == :hiredis
  # Using a mock server in a thread doesn't work here (possibly because blocking
  # socket ops, raw socket timeouts and Ruby's thread scheduling don't mix).
  test "Bubble EAGAIN without retrying" do
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
