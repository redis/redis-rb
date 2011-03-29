# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

setup do
  log = StringIO.new

  [Redis.new(OPTIONS.merge(:logger => ::Logger.new(log))), log]
end

$TEST_PIPELINING = true
$TEST_INSPECT    = true

load File.expand_path("./lint/internals.rb", File.dirname(__FILE__))

test "Redis.current" do
  Redis.current.set("foo", "bar")

  assert "bar" == Redis.current.get("foo")

  Redis.current = Redis.new(OPTIONS.merge(:db => 14))

  assert Redis.current.get("foo").nil?
end

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

test_with_mocha "Bubble EAGAIN without retrying" do |redis,log|
  redis.client.connection.stubs(:read).raises(Errno::EAGAIN).once
  assert_raise(Errno::EAGAIN) { redis.ping }
end

test "Connecting to UNIX domain socket" do
  assert_nothing_raised do
    Redis.new(OPTIONS.merge(:path => "/tmp/redis.sock")).ping
  end
end
