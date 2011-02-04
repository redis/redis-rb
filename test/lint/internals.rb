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
    Redis.new(OPTIONS.merge(:host => "127.0.0.2", :timeout => 1)).ping
  rescue Timeout::Error
    result = true
  ensure
    assert result
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

