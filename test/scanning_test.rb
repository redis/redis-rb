# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestScanning < Test::Unit::TestCase

  include Helper::Client

  def test_scan_basic
    target_version "2.7.105" do
      r.debug :populate, 1000

      cursor = 0
      all_keys   = []
      loop {
        cursor, keys = r.scan cursor
        all_keys += keys
        break if cursor == "0"
      }

      assert_equal 1000, all_keys.uniq.size
    end
  end

  def test_scan_count
    target_version "2.7.105" do
      r.debug :populate, 1000

      cursor = 0
      all_keys   = []
      loop {
        cursor, keys = r.scan cursor, :count => 5
        all_keys += keys
        break if cursor == "0"
      }

      assert_equal 1000, all_keys.uniq.size
    end
  end

  def test_scan_match
    target_version "2.7.105" do
      r.debug :populate, 1000

      cursor = 0
      all_keys   = []
      loop {
        cursor, keys = r.scan cursor, :match => "key:1??"
        all_keys += keys
        break if cursor == "0"
      }

      assert_equal 100, all_keys.uniq.size
    end
  end

  def test_sscan_with_encoding
    target_version "2.7.105" do
      [:intset, :hashtable].each do |enc|
        r.del "set"

        prefix = ""
        prefix = "ele:" if enc == :hashtable

        elements = []
        100.times { |j| elements << "#{prefix}#{j}" }

        r.sadd "set", elements

        assert_equal enc.to_s, r.object("encoding", "set")

        cursor = 0
        all_keys   = []
        loop {
          cursor, keys = r.sscan "set", cursor
          all_keys += keys
          break if cursor == "0"
        }

        assert_equal 100, all_keys.uniq.size
      end
    end
  end

  def test_hscan_with_encoding
    target_version "2.7.105" do
      [:ziplist, :hashtable].each do |enc|
        r.del "set"

        count = 1000
        count = 30 if enc == :ziplist

        elements = []
        count.times { |j| elements << "key:#{j}" << j.to_s }

        r.hmset "hash", *elements

        assert_equal enc.to_s, r.object("encoding", "hash")

        cursor = 0
        all_keys   = []
        loop {
          cursor, keys = r.hscan "hash", cursor
          all_keys += keys
          break if cursor == "0"
        }

        keys2 = []
        all_keys.each_slice(2) do |k, v|
          assert_equal "key:#{v}", k
          keys2 << k
        end

        assert_equal count, keys2.uniq.size
      end
    end
  end

  def test_zscan_with_encoding
    target_version "2.7.105" do
      [:ziplist, :skiplist].each do |enc|
        r.del "zset"

        count = 1000
        count = 30 if enc == :ziplist

        elements = []
        count.times { |j| elements << j << "key:#{j}" }

        r.zadd "zset", elements

        assert_equal enc.to_s, r.object("encoding", "zset")

        cursor = 0
        all_keys   = []
        loop {
          cursor, keys = r.zscan "zset", cursor
          all_keys += keys
          break if cursor == "0"
        }

        keys2 = []
        all_keys.each_slice(2) do |k, v|
          assert_equal "key:#{v}", k
          keys2 << k
        end

        assert_equal count, keys2.uniq.size
      end
    end
  end
end
