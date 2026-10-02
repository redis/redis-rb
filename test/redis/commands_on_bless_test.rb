# frozen_string_literal: true

require "helper"

class TestCommandsOnBless < Minitest::Test
  include Helper::Client
  include Lint::Bless

  def test_bless_wire_shape
    calls = []
    handler = lambda do |*args|
      calls << args
      case args.first
      when "GET" then ["NO-EVICT"]
      when "SCAN" then ["0", ["k1", "k2"]]
      else ":1"
      end
    end

    redis_mock(bless: handler) do |redis|
      assert_equal ["NO-EVICT"], redis.bless_get("k")
      assert_equal true, redis.bless_set("k", "NO-EVICT")
      # The flag is passed through verbatim: no client-side normalization.
      assert_equal true, redis.bless_clear("k", "no-evict")
      assert_equal ["0", %w[k1 k2]], redis.bless_scan(0, "NO-EVICT")
      assert_equal ["0", %w[k1 k2]], redis.bless_scan("17", "NO-EVICT", count: 10)
    end

    assert_equal ["GET", "k"], calls[0]
    assert_equal ["SET", "k", "NO-EVICT"], calls[1]
    assert_equal ["CLEAR", "k", "no-evict"], calls[2]
    assert_equal ["SCAN", "0", "NO-EVICT"], calls[3]
    assert_equal ["SCAN", "17", "NO-EVICT", "COUNT", "10"], calls[4]
  end

  def test_bless_set_and_clear_boolify_zero
    handler = ->(*_) { ":0" }

    redis_mock(bless: handler) do |redis|
      assert_equal false, redis.bless_set("k", "NO-EVICT")
      assert_equal false, redis.bless_clear("k", "NO-EVICT")
    end
  end

  def test_bless_scan_rejects_non_integer_count
    assert_raises(ArgumentError) { r.bless_scan(0, "NO-EVICT", count: "ten") }
  end

  def test_bless_scan_each_returns_enumerator_without_block
    assert_kind_of Enumerator, r.bless_scan_each("NO-EVICT")
  end

  def test_bless_scan
    target_version "8.12" do
      blessed = %w[b1 b2 b3]
      (blessed + %w[plain1 plain2]).each { |key| r.set(key, "v") }
      blessed.each { |key| r.bless_set(key, "NO-EVICT") }

      cursor = 0
      found = []
      loop do
        cursor, keys = r.bless_scan(cursor, "NO-EVICT")
        found.concat(keys)
        break if cursor == "0"
      end

      assert_equal blessed, found.uniq.sort
    end
  end

  def test_bless_scan_with_count
    target_version "8.12" do
      blessed = (1..20).map { |i| format("b%02d", i) }
      blessed.each do |key|
        r.set(key, "v")
        r.bless_set(key, "NO-EVICT")
      end

      cursor = 0
      found = []
      loop do
        cursor, keys = r.bless_scan(cursor, "NO-EVICT", count: 5)
        found.concat(keys)
        break if cursor == "0"
      end

      assert_equal blessed, found.uniq.sort
    end
  end

  def test_bless_scan_each
    target_version "8.12" do
      blessed = %w[b1 b2 b3]
      (blessed + %w[plain1 plain2]).each { |key| r.set(key, "v") }
      blessed.each { |key| r.bless_set(key, "NO-EVICT") }

      assert_equal blessed, r.bless_scan_each("NO-EVICT").to_a.uniq.sort

      yielded = []
      r.bless_scan_each("NO-EVICT", count: 2) { |key| yielded << key }
      assert_equal blessed, yielded.uniq.sort
    end
  end

  def test_bless_scan_each_with_no_blessed_keys
    target_version "8.12" do
      r.set("foo", "bar")

      assert_equal [], r.bless_scan_each("NO-EVICT").to_a
    end
  end

  def test_bless_in_pipeline
    target_version "8.12" do
      r.set("foo", "bar")

      set_first, set_again, flags, cleared, scanned = r.pipelined do |pipe|
        pipe.bless_set("foo", "NO-EVICT")
        pipe.bless_set("foo", "NO-EVICT")
        pipe.bless_get("foo")
        pipe.bless_clear("foo", "NO-EVICT")
        pipe.bless_scan(0, "NO-EVICT")
      end

      assert_equal true, set_first
      assert_equal false, set_again
      assert_equal ["NO-EVICT"], flags
      assert_equal true, cleared
      assert_equal ["0", []], scanned
    end
  end

  def test_bless_in_multi
    target_version "8.12" do
      r.set("foo", "bar")

      result = r.multi do |tx|
        tx.bless_set("foo", "NO-EVICT")
        tx.bless_get("foo")
      end

      assert_equal [true, ["NO-EVICT"]], result
    end
  end
end
