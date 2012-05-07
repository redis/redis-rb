# encoding: UTF-8

require "helper"

class TestPublishSubscribe < Test::Unit::TestCase

  include Helper

  def test_subscribe_and_unsubscribe
    listening = false

    wire = Wire.new do
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

        listening = true
      end
    end

    Wire.pass while !listening

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert @subscribed
    assert 1 == @t1
    assert @unsubscribed
    assert 0 == @t2
    assert "s1" == @message
  end

  def test_psubscribe_and_punsubscribe
    listening = false

    wire = Wire.new do
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

    Wire.pass while !listening

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert @subscribed
    assert 1 == @t1
    assert @unsubscribed
    assert 0 == @t2
    assert "s1" == @message
  end

  def test_subscribe_within_subscribe
    listening = false

    @channels = []

    wire = Wire.new do
      r.subscribe("foo") do |on|
        on.subscribe do |channel, total|
          @channels << channel

          r.subscribe("bar") if channel == "foo"
          r.unsubscribe if channel == "bar"
        end

        listening = true
      end
    end

    Wire.pass while !listening

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert ["foo", "bar"] == @channels
  end

  def test_other_commands_within_a_subscribe
    assert_raise Redis::CommandError do
      r.subscribe("foo") do |on|
        on.subscribe do |channel, total|
          r.set("bar", "s2")
        end
      end
    end
  end

  def test_subscribe_without_a_block
    assert_raise LocalJumpError do
      r.subscribe("foo")
    end
  end

  def test_unsubscribe_without_a_subscribe
    assert_raise RuntimeError do
      r.unsubscribe
    end

    assert_raise RuntimeError do
      r.punsubscribe
    end
  end

  def test_subscribe_past_a_timeout
    # For some reason, a thread here doesn't reproduce the issue.
    sleep = %{sleep #{OPTIONS[:timeout] * 2}}
    publish = %{echo "publish foo bar\r\n" | nc localhost #{OPTIONS[:port]}}
    cmd = [sleep, publish].join("; ")

    IO.popen(cmd, "r+") do |pipe|
      received = false

      r.subscribe "foo" do |on|
        on.message do |channel, message|
          received = true
          r.unsubscribe
        end
      end

      assert received
    end
  end
end
