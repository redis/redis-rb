# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "SUBSCRIBE and UNSUBSCRIBE" do |r|
  thread = Thread.new do
    r.subscribe("foo") do |on|
      on.subscribe do |channel, total|
        @subscribed = true
        @t1 = total
      end

      on.message do |channel, message|
        if message == "s1"
          r.unsubscribe
          @message = message
        end
      end

      on.unsubscribe do |channel, total|
        @unsubscribed = true
        @t2 = total
      end
    end
  end

  Redis.new(OPTIONS).publish("foo", "s1")

  thread.join

  assert @subscribed
  assert 1 == @t1
  assert @unsubscribed
  assert 0 == @t2
  assert "s1" == @message
end

test "PSUBSCRIBE and PUNSUBSCRIBE" do |r|
  listening = false

  thread = Thread.new do
    r.psubscribe("f*") do |on|
      on.psubscribe do |pattern, total|
        @subscribed = true
        @t1 = total
      end

      on.pmessage do |pattern, channel, message|
        if message == "s1"
          r.punsubscribe
          @message = message
        end
      end

      on.punsubscribe do |pattern, total|
        @unsubscribed = true
        @t2 = total
      end

      listening = true
    end
  end

  while !listening; end

  Redis.new(OPTIONS).publish("foo", "s1")

  thread.join

  assert @subscribed
  assert 1 == @t1
  assert @unsubscribed
  assert 0 == @t2
  assert "s1" == @message
end

test "SUBSCRIBE within SUBSCRIBE" do |r|
  listening = false

  @channels = []

  thread = Thread.new do
    r.subscribe("foo") do |on|
      on.subscribe do |channel, total|
        @channels << channel

        r.subscribe("bar") if channel == "foo"
        r.unsubscribe if channel == "bar"
      end

      listening = true
    end
  end

  while !listening; end

  Redis.new(OPTIONS).publish("foo", "s1")

  thread.join

  assert ["foo", "bar"] == @channels
end

test "other commands within a SUBSCRIBE" do |r|
  assert_raise RuntimeError do
    r.subscribe("foo") do |on|
      on.subscribe do |channel, total|
        r.set("bar", "s2")
      end
    end
  end
end

test "SUBSCRIBE without a block" do |r|
  assert_raise LocalJumpError do
    r.subscribe("foo")
  end
end

test "UNSUBSCRIBE without a SUBSCRIBE" do |r|
  assert_raise RuntimeError do
    r.unsubscribe
  end

  assert_raise RuntimeError do
    r.punsubscribe
  end
end

test "SUBSCRIBE past a timeout" do |r|
  # For some reason, a thread here doesn't reproduce the issue.
  fork do
    sleep OPTIONS[:timeout] + 1
    Redis.new(OPTIONS).publish "foo", "bar"
  end

  received = false

  r.subscribe "foo" do |on|
    on.message do |channel, message|
      received = true
      r.unsubscribe
    end
  end

  assert received
end
