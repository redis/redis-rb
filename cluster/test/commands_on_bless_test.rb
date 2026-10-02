# frozen_string_literal: true

require "helper"

class TestClusterCommandsOnBless < Minitest::Test
  include Helper::Cluster
  include Lint::Bless

  # BLESS SCAN is keyless; redis-cluster-client walks it node by node the way it does
  # SCAN, encoding the node index into the cursor, so a full iteration reaches the
  # blessed keys of every shard.
  def test_bless_scan_reaches_every_shard
    target_version "8.12" do
      # Distinct hash tags so the keys spread over the three shards.
      keys = (1..30).map { |i| "{bless#{i}}key" }
      keys.each do |key|
        redis.set(key, "bar")
        redis.bless_set(key, "NO-EVICT")
      end

      found = []
      cursor = 0
      loop do
        cursor, batch = redis.bless_scan(cursor, "NO-EVICT", count: 5)
        assert_kind_of String, cursor
        found.concat(batch)
        break if cursor == "0"
      end

      assert_equal keys.sort, found.sort.uniq
    end
  end

  def test_bless_scan_each
    target_version "8.12" do
      keys = (1..10).map { |i| "{bless#{i}}key" }
      keys.each do |key|
        redis.set(key, "bar")
        redis.bless_set(key, "NO-EVICT")
      end

      assert_equal keys.sort, redis.bless_scan_each("NO-EVICT").to_a.sort.uniq
    end
  end

  def test_bless_scan_in_pipeline
    target_version "8.12" do
      redis.set("{bless}foo", "bar")

      blessed, scanned = redis.pipelined do |pipe|
        pipe.bless_set("{bless}foo", "NO-EVICT")
        pipe.bless_scan(0, "NO-EVICT")
      end

      assert_equal true, blessed
      assert_kind_of String, scanned[0]
      assert_kind_of Array, scanned[1]
    end
  end
end
