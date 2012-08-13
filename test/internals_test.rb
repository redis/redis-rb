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

  driver(:ruby) do
    def test_tcp_keepalive
      keepalive = {:time => 20, :intvl => 10, :probes => 5}

      redis = Redis.new(OPTIONS.merge(:tcp_keepalive => keepalive))
      redis.ping

      connection = redis.client.connection
      actual_keepalive = connection.get_tcp_keepalive

      [:time, :intvl, :probes].each do |key|
        if actual_keepalive.has_key?(key)
          assert_equal actual_keepalive[key], keepalive[key]
        end
      end
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

  def close_on_ping(seq)
    $request = 0

    command = lambda do
      idx = $request
      $request += 1

      rv = "+%d" % idx
      rv = nil if seq.include?(idx)
      rv
    end

    redis_mock(:ping => command, :timeout => 0.1) do |redis|
      yield(redis)
    end
  end

  def test_retry_by_default
    close_on_ping([0]) do |redis|
      assert_equal "1", redis.ping
    end
  end

  def test_retry_when_wrapped_in_with_reconnect_true
    close_on_ping([0]) do |redis|
      redis.with_reconnect(true) do
        assert_equal "1", redis.ping
      end
    end
  end

  def test_dont_retry_when_wrapped_in_with_reconnect_false
    close_on_ping([0]) do |redis|
      assert_raise Redis::ConnectionError do
        redis.with_reconnect(false) do
          redis.ping
        end
      end
    end
  end

  def test_dont_retry_when_wrapped_in_without_reconnect
    close_on_ping([0]) do |redis|
      assert_raise Redis::ConnectionError do
        redis.without_reconnect do
          redis.ping
        end
      end
    end
  end

  def test_retry_only_once_when_read_raises_econnreset
    close_on_ping([0, 1]) do |redis|
      assert_raise Redis::ConnectionError do
        redis.ping
      end

      assert !redis.client.connected?
    end
  end

  def test_don_t_retry_when_second_read_in_pipeline_raises_econnreset
    close_on_ping([1]) do |redis|
      assert_raise Redis::ConnectionError do
        redis.pipelined do
          redis.ping
          redis.ping # Second #read times out
        end
      end

      assert !redis.client.connected?
    end
  end

  def close_on_connection(seq)
    $n = 0

    read_command = lambda do |session|
      Array.new(session.gets[1..-3].to_i) do
        bytes = session.gets[1..-3].to_i
        arg = session.read(bytes)
        session.read(2) # Discard \r\n
        arg
      end
    end

    handler = lambda do |session|
      n = $n
      $n += 1

      select = read_command.call(session)
      if select[0].downcase == "select"
        session.write("+OK\r\n")
      else
        raise "Expected SELECT"
      end

      if !seq.include?(n)
        while read_command.call(session)
          session.write("+#{n}\r\n")
        end
      end
    end

    redis_mock_with_handler(handler) do |redis|
      yield(redis)
    end
  end

  def test_retry_on_write_error_by_default
    close_on_connection([0]) do |redis|
      assert_equal "1", redis.client.call(["x" * 128 * 1024])
    end
  end

  def test_retry_on_write_error_when_wrapped_in_with_reconnect_true
    close_on_connection([0]) do |redis|
      redis.with_reconnect(true) do
        assert_equal "1", redis.client.call(["x" * 128 * 1024])
      end
    end
  end

  def test_dont_retry_on_write_error_when_wrapped_in_with_reconnect_false
    close_on_connection([0]) do |redis|
      assert_raise Redis::ConnectionError do
        redis.with_reconnect(false) do
          redis.client.call(["x" * 128 * 1024])
        end
      end
    end
  end

  def test_dont_retry_on_write_error_when_wrapped_in_without_reconnect
    close_on_connection([0]) do |redis|
      assert_raise Redis::ConnectionError do
        redis.without_reconnect do
          redis.client.call(["x" * 128 * 1024])
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
