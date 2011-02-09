test "Logger" do |r, log|
  r.ping

  assert log.string =~ /Redis >> PING/
  assert log.string =~ /Redis >> \d+\.\d+ms/
end

test "Logger with pipelining" do |r, log|
  r.pipelined do
    r.set "foo", "bar"
    r.get "foo"
  end

  assert log.string["SET foo bar"]
  assert log.string["GET foo"]
end if $TEST_PIPELINING

test "Timeout" do
  assert_nothing_raised do
    Redis.new(OPTIONS.merge(:timeout => 0))
  end
end

# Don't use assert_raise because Timeour::Error in 1.8 inherits
# Exception instead of StandardError (on 1.9).
test "Connection timeout" do
  result = false

  begin
    Redis.new(OPTIONS.merge(:host => "10.255.255.254", :timeout => 0.1)).ping
  rescue Timeout::Error
    result = true
  ensure
    assert result
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
    redis = Redis.connect(:port => 6380, :timeout => 0.1)
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
    redis = Redis.connect(:port => 6380, :timeout => 0.1)
    assert_raise Errno::ECONNRESET do
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
    redis = Redis.connect(:port => 6380, :timeout => 0.1)
    assert_raise Errno::ECONNRESET do
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
    redis = Redis.connect(:port => 6380, :timeout => 0.1)
    assert_raise Errno::ECONNRESET do
      redis.pipelined do
        redis.ping
        redis.ping # Second #read times out
      end
    end
  end
end

test "Don't retry when read raises EAGAIN" do
  command = lambda do
    sleep(0.2)
    "+PONG"
  end

  redis_mock(:ping => command) do
    redis = Redis.connect(:port => 6380, :timeout => 0.1)
    assert_raise(Errno::EAGAIN) { redis.ping }
  end
end

test "Connecting to UNIX domain socket" do
  assert_nothing_raised do
    Redis.new(OPTIONS.merge(:path => "/tmp/redis.sock")).ping
  end
end

test "Recovers from failed commands" do |r, _|
  # See http://github.com/ezmobius/redis-rb/issues#issue/28

  assert_raise(ArgumentError) do
    r.srem "foo"
  end

  assert_nothing_raised do
    r.info
  end
end

test "provides a meaningful inspect" do |r, _|
  assert "#<Redis client v#{Redis::VERSION} connected to redis://127.0.0.1:6379/15 (Redis v#{r.info["redis_version"]})>" == r.inspect
end if $TEST_INSPECT

test "raises on protocol errors" do
  redis_mock(:ping => lambda { |*_| "foo" }) do
    assert_raise(Redis::ProtocolError) do
      Redis.connect(:port => 6380).ping
    end
  end
end

