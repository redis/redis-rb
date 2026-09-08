# frozen_string_literal: true

require "helper"

class TestCommandsOnSortedSets < Minitest::Test
  include Helper::Client
  include Lint::SortedSets

  # Core Redis never stores a NaN score, but Redis 7.2 normalizes any NaN a reply carries (Lua,
  # modules) to a "nan" bulk string under RESP2 and a NaN double under RESP3. Both must reach the
  # caller as Float::NAN instead of raising from Float("nan").
  def nan_reply
    PROTOCOL == 3 ? ",nan\r\n" : "$3\r\nnan\r\n"
  end

  def test_floatify_handles_nan
    assert_predicate Redis::Commands::Floatify.call("nan"), :nan?
    assert_predicate Redis::Commands::Floatify.call(Float::NAN), :nan?
    assert_equal Float::INFINITY, Redis::Commands::Floatify.call("inf")
  end

  def test_zscore_with_a_nan_reply
    redis_mock(zscore: ->(*_) { nan_reply }) do |redis|
      assert_predicate redis.zscore("foo", "s1"), :nan?
    end
  end

  def test_zincrby_with_a_nan_reply
    redis_mock(zincrby: ->(*_) { nan_reply }) do |redis|
      assert_predicate redis.zincrby("foo", 1, "s1"), :nan?
    end
  end

  def test_zrange_with_scores_with_a_nan_reply
    reply = if PROTOCOL == 3
      "*1\r\n*2\r\n$2\r\ns1\r\n,nan\r\n"
    else
      "*2\r\n$2\r\ns1\r\n$3\r\nnan\r\n"
    end

    redis_mock(zrange: ->(*_) { reply }) do |redis|
      member, score = redis.zrange("foo", 0, -1, with_scores: true).first

      assert_equal "s1", member
      assert_predicate score, :nan?
    end
  end
end
