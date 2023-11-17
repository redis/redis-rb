# frozen_string_literal: true

require "helper"

class TestPublishSubscribe < Minitest::Test
  include Helper::Client

  def setup
    @threads = {}
    super
  end

  def teardown
    super
    @threads.each do |thread, redis|
      if redis.subscribed?
        redis.unsubscribe
        redis.punsubscribe
      end
      redis.close
      begin
        thread.join(2) or warn("leaked thread")
      rescue RedisClient::ConnectionError
      end
    end
  end

  class TestError < StandardError
  end

  def test_subscribe_and_unsubscribe
    @subscribed = false
    @unsubscribed = false

    thread = new_thread do |r|
      r.subscribe(channel_name) do |on|
        on.subscribe do |_channel, total|
          @subscribed = true
          @t1 = total
        end

        on.message do |_channel, message|
          if message == "s1"
            r.unsubscribe
            @message = message
          end
        end

        on.unsubscribe do |_channel, total|
          @unsubscribed = true
          @t2 = total
        end
      end
    end

    # Wait until the subscription is active before publishing
    Thread.pass until @subscribed

    redis.publish(channel_name, "s1")
    thread.join

    assert @subscribed
    assert_equal 1, @t1
    assert @unsubscribed
    assert_equal 0, @t2
    assert_equal "s1", @message
  end

  def test_psubscribe_and_punsubscribe
    @subscribed = false
    @unsubscribed = false

    thread = new_thread do |r|
      r.psubscribe("channel:*") do |on|
        on.psubscribe do |_pattern, total|
          @subscribed = true
          @t1 = total
        end

        on.pmessage do |_pattern, _channel, message|
          if message == "s1"
            r.punsubscribe
            @message = message
          end
        end

        on.punsubscribe do |_pattern, total|
          @unsubscribed = true
          @t2 = total
        end
      end
    end

    # Wait until the subscription is active before publishing
    Thread.pass until @subscribed
    redis.publish(channel_name, "s1")
    thread.join

    assert @subscribed
    assert_equal 1, @t1
    assert @unsubscribed
    assert_equal 0, @t2
    assert_equal "s1", @message
  end

  def test_pubsub_with_channels_and_numsub_subcommnads
    @subscribed = false
    thread = new_thread do |r|
      r.subscribe(channel_name) do |on|
        on.subscribe { |_channel, _total| @subscribed = true }
        on.message   { |_channel, _message| r.unsubscribe }
      end
    end
    Thread.pass until @subscribed
    channels_result = redis.pubsub(:channels)
    channels_result.delete('__sentinel__:hello')
    numsub_result = redis.pubsub(:numsub, channel_name, 'boo')

    redis.publish(channel_name, "s1")
    thread.join

    assert_includes channels_result, channel_name
    assert_equal [channel_name, 1, 'boo', 0], numsub_result
  end

  def test_subscribe_connection_usable_after_raise
    @subscribed = false

    thread = new_thread do |r|
      r.subscribe(channel_name) do |on|
        on.subscribe do |_channel, _total|
          @subscribed = true
        end

        on.message do |_channel, _message|
          r.unsubscribe
          raise TestError
        end
      end
    rescue TestError
    end

    # Wait until the subscription is active before publishing
    Thread.pass until @subscribed

    redis.publish(channel_name, "s1")

    thread.join

    assert_equal "PONG", r.ping
  end

  def test_psubscribe_connection_usable_after_raise
    @subscribed = false

    thread = new_thread do |r|
      r.psubscribe("channel:*") do |on|
        on.psubscribe do |_pattern, _total|
          @subscribed = true
        end

        on.pmessage do |_pattern, _channel, _message|
          raise TestError
        end
      end
    rescue TestError
    end

    # Wait until the subscription is active before publishing
    Thread.pass until @subscribed

    redis.publish(channel_name, "s1")

    thread.join

    assert_equal "PONG", r.ping
  end

  def test_subscribe_within_subscribe
    @channels = Queue.new

    thread = new_thread do |r|
      r.subscribe(channel_name) do |on|
        on.subscribe do |channel, _total|
          @channels << channel

          r.subscribe("bar") if channel == channel_name
          r.unsubscribe if channel == "bar"
        end
      end
    end

    thread.join

    assert_equal [channel_name, "bar"], [@channels.pop, @channels.pop]
    assert_empty @channels
  end

  def test_other_commands_within_a_subscribe
    r.subscribe(channel_name) do |on|
      on.subscribe do |_channel, _total|
        r.set("bar", "s2")
        r.unsubscribe(channel_name)
      end
    end
  end

  def test_subscribe_without_a_block
    error = assert_raises Redis::SubscriptionError do
      r.subscribe(channel_name)
    end
    assert_includes "This client is not subscribed", error.message
  end

  def test_unsubscribe_without_a_subscribe
    error = assert_raises Redis::SubscriptionError do
      r.unsubscribe
    end
    assert_includes "This client is not subscribed", error.message

    error = assert_raises Redis::SubscriptionError do
      r.punsubscribe
    end
    assert_includes "This client is not subscribed", error.message
  end

  def test_subscribe_past_a_timeout
    # For some reason, a thread here doesn't reproduce the issue.
    sleep = %(sleep 0.05)
    publish = %{ruby -rsocket -e 't=TCPSocket.new("127.0.0.1",#{OPTIONS[:port]});t.write("publish foo bar\\r\\n");t.read(4);t.close'}
    cmd = [sleep, publish].join('; ')

    IO.popen(cmd, 'r+') do |_pipe|
      received = false

      r.subscribe 'foo' do |on|
        on.message do |_channel, _message|
          received = true
          r.unsubscribe
        end
      end

      assert received
    end
  end

  def test_subscribe_with_timeout
    received = false

    r.subscribe_with_timeout(LOW_TIMEOUT, channel_name) do |on|
      on.message do |_channel, _message|
        received = true
      end
    end

    refute received
  end

  def test_psubscribe_with_timeout
    received = false

    r.psubscribe_with_timeout(LOW_TIMEOUT, "channel:*") do |on|
      on.message do |_channel, _message|
        received = true
      end
    end

    refute received
  end

  def test_unsubscribe_from_another_thread
    @unsubscribed = @subscribed = false
    @subscribed_redis = nil
    @messages = Queue.new
    thread = new_thread do |r|
      @subscribed_redis = r
      r.subscribe(channel_name) do |on|
        on.subscribe do |_channel, _total|
          @subscribed = true
        end

        on.message do |channel, message|
          @messages << [channel, message]
        end

        on.unsubscribe do |_channel, _total|
          @unsubscribed = true
        end
      end
    end

    Thread.pass until @subscribed

    redis.publish(channel_name, "test")
    assert_equal [channel_name, "test"], @messages.pop
    assert_empty @messages

    @subscribed_redis.unsubscribe # this shouldn't block
    refute_nil thread.join(2)
    assert_equal true, @unsubscribed
  end

  def test_subscribe_from_another_thread
    @events = Queue.new
    @subscribed_redis = nil
    thread = new_thread do |r|
      r.subscribe(channel_name) do |on|
        @subscribed_redis = r
        on.subscribe do |channel, _total|
          @events << ["subscribed", channel]
        end

        on.message do |channel, message|
          @events << ["message", channel, message]
        end

        on.unsubscribe do |channel, _total|
          @events << ["unsubscribed", channel]
        end
      end
    end

    Thread.pass until @subscribed_redis&.subscribed?

    redis.publish(channel_name, "test")
    @subscribed_redis.subscribe("#{channel_name}:2")
    redis.publish("#{channel_name}:2", "test-2")

    @subscribed_redis.unsubscribe(channel_name)
    @subscribed_redis.unsubscribe # this shouldn't block

    refute_nil thread.join(2)
    expected = [
      ["subscribed", channel_name],
      ["message", channel_name, "test"],
      ["subscribed", "#{channel_name}:2"],
      ["message", "#{channel_name}:2", "test-2"],
      ["unsubscribed", channel_name],
      ["unsubscribed", "#{channel_name}:2"]
    ]
    assert_equal(expected, expected.map { @events.pop })
    assert_empty @events
  end

  private

  def new_thread(&block)
    redis = Redis.new(OPTIONS)
    thread = Thread.new(redis, &block)
    thread.report_on_exception = true
    @threads[thread] = redis
    thread
  end

  def channel_name
    @channel_name ||= "channel:#{rand}"
  end
end
