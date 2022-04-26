# frozen_string_literal: true

module Lint
  module SortedSets
    def test_zadd
      assert_equal 0, r.zcard("foo")
      assert_equal true, r.zadd("foo", 1, "s1")
      assert_equal false, r.zadd("foo", 1, "s1")
      assert_equal 1, r.zcard("foo")
      r.del "foo"

      target_version "3.0.2" do
        # XX option
        assert_equal 0, r.zcard("foo")
        assert_equal false, r.zadd("foo", 1, "s1", xx: true)
        r.zadd("foo", 1, "s1")
        assert_equal false, r.zadd("foo", 2, "s1", xx: true)
        assert_equal 2, r.zscore("foo", "s1")
        r.del "foo"

        # NX option
        assert_equal 0, r.zcard("foo")
        assert_equal true, r.zadd("foo", 1, "s1", nx: true)
        assert_equal false, r.zadd("foo", 2, "s1", nx: true)
        assert_equal 1, r.zscore("foo", "s1")
        assert_equal 1, r.zcard("foo")
        r.del "foo"

        # CH option
        assert_equal 0, r.zcard("foo")
        assert_equal true, r.zadd("foo", 1, "s1", ch: true)
        assert_equal false, r.zadd("foo", 1, "s1", ch: true)
        assert_equal true, r.zadd("foo", 2, "s1", ch: true)
        assert_equal 1, r.zcard("foo")
        r.del "foo"

        # INCR option
        assert_equal 1.0, r.zadd("foo", 1, "s1", incr: true)
        assert_equal 11.0, r.zadd("foo", 10, "s1", incr: true)
        assert_equal(-Float::INFINITY, r.zadd("bar", "-inf", "s1", incr: true))
        assert_equal(+Float::INFINITY, r.zadd("bar", "+inf", "s2", incr: true))
        r.del 'foo'
        r.del 'bar'

        # Incompatible options combination
        assert_raises(Redis::CommandError) { r.zadd("foo", 1, "s1", xx: true, nx: true) }
      end

      target_version "6.2" do
        # LT option
        r.zadd("foo", 2, "s1")

        r.zadd("foo", 3, "s1", lt: true)
        assert_equal 2.0, r.zscore("foo", "s1")

        r.zadd("foo", 1, "s1", lt: true)
        assert_equal 1.0, r.zscore("foo", "s1")

        assert_equal true, r.zadd("foo", 3, "s2", lt: true) # adds new member
        r.del "foo"

        # GT option
        r.zadd("foo", 2, "s1")

        r.zadd("foo", 1, "s1", gt: true)
        assert_equal 2.0, r.zscore("foo", "s1")

        r.zadd("foo", 3, "s1", gt: true)
        assert_equal 3.0, r.zscore("foo", "s1")

        assert_equal true, r.zadd("foo", 1, "s2", gt: true) # adds new member
        r.del "foo"

        # Incompatible options combination
        assert_raises(Redis::CommandError) { r.zadd("foo", 1, "s1", nx: true, gt: true) }
      end
    end

    def test_variadic_zadd
      target_version "2.3.9" do # 2.4-rc6
        # Non-nested array with pairs
        assert_equal 0, r.zcard("foo")

        assert_equal 2, r.zadd("foo", [1, "s1", 2, "s2"])
        assert_equal 2, r.zcard("foo")

        assert_equal 1, r.zadd("foo", [4, "s1", 5, "s2", 6, "s3"])
        assert_equal 3, r.zcard("foo")

        r.del "foo"

        # Nested array with pairs
        assert_equal 0, r.zcard("foo")

        assert_equal 2, r.zadd("foo", [[1, "s1"], [2, "s2"]])
        assert_equal 2, r.zcard("foo")

        assert_equal 1, r.zadd("foo", [[4, "s1"], [5, "s2"], [6, "s3"]])
        assert_equal 3, r.zcard("foo")

        r.del "foo"

        # Empty array
        assert_equal 0, r.zcard("foo")

        assert_equal 0, r.zadd("foo", [])
        assert_equal 0, r.zcard("foo")

        r.del "foo"

        # Wrong number of arguments
        assert_raises(Redis::CommandError) { r.zadd("foo", ["bar"]) }
        assert_raises(Redis::CommandError) { r.zadd("foo", ["bar", "qux", "zap"]) }
      end

      target_version "3.0.2" do
        # XX option
        assert_equal 0, r.zcard("foo")
        assert_equal 0, r.zadd("foo", [1, "s1", 2, "s2"], xx: true)
        r.zadd("foo", [1, "s1", 2, "s2"])
        assert_equal 0, r.zadd("foo", [2, "s1", 3, "s2", 4, "s3"], xx: true)
        assert_equal 2, r.zscore("foo", "s1")
        assert_equal 3, r.zscore("foo", "s2")
        assert_nil r.zscore("foo", "s3")
        assert_equal 2, r.zcard("foo")
        r.del "foo"

        # NX option
        assert_equal 0, r.zcard("foo")
        assert_equal 2, r.zadd("foo", [1, "s1", 2, "s2"], nx: true)
        assert_equal 1, r.zadd("foo", [2, "s1", 3, "s2", 4, "s3"], nx: true)
        assert_equal 1, r.zscore("foo", "s1")
        assert_equal 2, r.zscore("foo", "s2")
        assert_equal 4, r.zscore("foo", "s3")
        assert_equal 3, r.zcard("foo")
        r.del "foo"

        # CH option
        assert_equal 0, r.zcard("foo")
        assert_equal 2, r.zadd("foo", [1, "s1", 2, "s2"], ch: true)
        assert_equal 2, r.zadd("foo", [1, "s1", 3, "s2", 4, "s3"], ch: true)
        assert_equal 3, r.zcard("foo")
        r.del "foo"

        # INCR option
        assert_equal 1.0, r.zadd("foo", [1, "s1"], incr: true)
        assert_equal 11.0, r.zadd("foo", [10, "s1"], incr: true)
        assert_equal(-Float::INFINITY, r.zadd("bar", ["-inf", "s1"], incr: true))
        assert_equal(+Float::INFINITY, r.zadd("bar", ["+inf", "s2"], incr: true))
        assert_raises(Redis::CommandError) { r.zadd("foo", [1, "s1", 2, "s2"], incr: true) }
        r.del 'foo'
        r.del 'bar'

        # Incompatible options combination
        assert_raises(Redis::CommandError) { r.zadd("foo", [1, "s1"], xx: true, nx: true) }
      end

      target_version "6.2" do
        # LT option
        r.zadd("foo", 2, "s1")

        assert_equal 1, r.zadd("foo", [3, "s1", 2, "s2"], lt: true, ch: true)
        assert_equal 2.0, r.zscore("foo", "s1")

        assert_equal 1, r.zadd("foo", [1, "s1"], lt: true, ch: true)

        r.del "foo"

        # GT option
        r.zadd("foo", 2, "s1")

        assert_equal 1, r.zadd("foo", [1, "s1", 2, "s2"], gt: true, ch: true)
        assert_equal 2.0, r.zscore("foo", "s1")

        assert_equal 1, r.zadd("foo", [3, "s1"], gt: true, ch: true)

        r.del "foo"
      end
    end

    def test_zrem
      r.zadd("foo", 1, "s1")
      r.zadd("foo", 2, "s2")

      assert_equal 2, r.zcard("foo")
      assert_equal true, r.zrem("foo", "s1")
      assert_equal false, r.zrem("foo", "s1")
      assert_equal 1, r.zcard("foo")
    end

    def test_variadic_zrem
      target_version "2.3.9" do # 2.4-rc6
        r.zadd("foo", 1, "s1")
        r.zadd("foo", 2, "s2")
        r.zadd("foo", 3, "s3")

        assert_equal 3, r.zcard("foo")

        assert_equal 0, r.zrem("foo", [])
        assert_equal 3, r.zcard("foo")

        assert_equal 1, r.zrem("foo", ["s1", "aaa"])
        assert_equal 2, r.zcard("foo")

        assert_equal 0, r.zrem("foo", ["bbb", "ccc", "ddd"])
        assert_equal 2, r.zcard("foo")

        assert_equal 1, r.zrem("foo", ["eee", "s3"])
        assert_equal 1, r.zcard("foo")
      end
    end

    def test_zincrby
      rv = r.zincrby "foo", 1, "s1"
      assert_equal 1.0, rv

      rv = r.zincrby "foo", 10, "s1"
      assert_equal 11.0, rv

      rv = r.zincrby "bar", "-inf", "s1"
      assert_equal(-Float::INFINITY, rv)

      rv = r.zincrby "bar", "+inf", "s2"
      assert_equal(+Float::INFINITY, rv)
    end

    def test_zrank
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"

      assert_equal 2, r.zrank("foo", "s3")
    end

    def test_zrevrank
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"

      assert_equal 0, r.zrevrank("foo", "s3")
    end

    def test_zrange
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"

      assert_equal ["s1", "s2"], r.zrange("foo", 0, 1)
      assert_equal [["s1", 1.0], ["s2", 2.0]], r.zrange("foo", 0, 1, with_scores: true)
      assert_equal [["s1", 1.0], ["s2", 2.0]], r.zrange("foo", 0, 1, withscores: true)

      r.zadd "bar", "-inf", "s1"
      r.zadd "bar", "+inf", "s2"
      assert_equal [["s1", -Float::INFINITY], ["s2", +Float::INFINITY]], r.zrange("bar", 0, 1, with_scores: true)
      assert_equal [["s1", -Float::INFINITY], ["s2", +Float::INFINITY]], r.zrange("bar", 0, 1, withscores: true)
    end

    def test_zrange_with_byscore
      target_version("6.2") do
        r.zadd "foo", 1, "s1"
        r.zadd "foo", 2, "s2"
        r.zadd "foo", 3, "s3"

        assert_equal ["s2", "s3"], r.zrange("foo", 2, 3, byscore: true)
        assert_equal ["s2", "s1"], r.zrange("foo", 2, 1, byscore: true, rev: true)
      end
    end

    def test_zrange_with_bylex
      target_version("6.2") do
        r.zadd "foo", 0, "aaren"
        r.zadd "foo", 0, "abagael"
        r.zadd "foo", 0, "abby"
        r.zadd "foo", 0, "abbygail"

        assert_equal %w[aaren abagael abby abbygail], r.zrange("foo", "[a", "[a\xff", bylex: true)
        assert_equal %w[aaren abagael], r.zrange("foo", "[a", "[a\xff", bylex: true, limit: [0, 2])
        assert_equal %w[abby abbygail], r.zrange("foo", "(abb", "(abb\xff", bylex: true)
        assert_equal %w[abbygail], r.zrange("foo", "(abby", "(abby\xff", bylex: true)
      end
    end

    def test_zrangestore
      target_version("6.2") do
        r.zadd "foo", 1, "s1"
        r.zadd "foo", 2, "s2"
        r.zadd "foo", 3, "s3"

        assert_equal 2, r.zrangestore("bar", "foo", 0, 1)
        assert_equal ["s1", "s2"], r.zrange("bar", 0, -1)

        assert_equal 2, r.zrangestore("baz", "foo", 2, 3, by_score: true)
        assert_equal ["s2", "s3"], r.zrange("baz", 0, -1)
      end
    end

    def test_zrevrange
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"

      assert_equal ["s3", "s2"], r.zrevrange("foo", 0, 1)
      assert_equal [["s3", 3.0], ["s2", 2.0]], r.zrevrange("foo", 0, 1, with_scores: true)
      assert_equal [["s3", 3.0], ["s2", 2.0]], r.zrevrange("foo", 0, 1, withscores: true)

      r.zadd "bar", "-inf", "s1"
      r.zadd "bar", "+inf", "s2"
      assert_equal [["s2", +Float::INFINITY], ["s1", -Float::INFINITY]], r.zrevrange("bar", 0, 1, with_scores: true)
      assert_equal [["s2", +Float::INFINITY], ["s1", -Float::INFINITY]], r.zrevrange("bar", 0, 1, withscores: true)
    end

    def test_zrangebyscore
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"

      assert_equal ["s2", "s3"], r.zrangebyscore("foo", 2, 3)
    end

    def test_zrevrangebyscore
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"

      assert_equal ["s3", "s2"], r.zrevrangebyscore("foo", 3, 2)
    end

    def test_zrangebyscore_with_limit
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"
      r.zadd "foo", 4, "s4"

      assert_equal ["s2"], r.zrangebyscore("foo", 2, 4, limit: [0, 1])
      assert_equal ["s3"], r.zrangebyscore("foo", 2, 4, limit: [1, 1])
      assert_equal ["s3", "s4"], r.zrangebyscore("foo", 2, 4, limit: [1, 2])
    end

    def test_zrevrangebyscore_with_limit
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"
      r.zadd "foo", 4, "s4"

      assert_equal ["s4"], r.zrevrangebyscore("foo", 4, 2, limit: [0, 1])
      assert_equal ["s3"], r.zrevrangebyscore("foo", 4, 2, limit: [1, 1])
      assert_equal ["s3", "s2"], r.zrevrangebyscore("foo", 4, 2, limit: [1, 2])
    end

    def test_zrangebyscore_with_withscores
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"
      r.zadd "foo", 4, "s4"

      assert_equal [["s2", 2.0]], r.zrangebyscore("foo", 2, 4, limit: [0, 1], with_scores: true)
      assert_equal [["s3", 3.0]], r.zrangebyscore("foo", 2, 4, limit: [1, 1], with_scores: true)
      assert_equal [["s2", 2.0]], r.zrangebyscore("foo", 2, 4, limit: [0, 1], withscores: true)
      assert_equal [["s3", 3.0]], r.zrangebyscore("foo", 2, 4, limit: [1, 1], withscores: true)

      r.zadd "bar", "-inf", "s1"
      r.zadd "bar", "+inf", "s2"
      assert_equal [["s1", -Float::INFINITY]], r.zrangebyscore("bar", -Float::INFINITY, +Float::INFINITY, limit: [0, 1], with_scores: true)
      assert_equal [["s2", +Float::INFINITY]], r.zrangebyscore("bar", -Float::INFINITY, +Float::INFINITY, limit: [1, 1], with_scores: true)
      assert_equal [["s1", -Float::INFINITY]], r.zrangebyscore("bar", -Float::INFINITY, +Float::INFINITY, limit: [0, 1], withscores: true)
      assert_equal [["s2", +Float::INFINITY]], r.zrangebyscore("bar", -Float::INFINITY, +Float::INFINITY, limit: [1, 1], withscores: true)
    end

    def test_zrevrangebyscore_with_withscores
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"
      r.zadd "foo", 4, "s4"

      assert_equal [["s4", 4.0]], r.zrevrangebyscore("foo", 4, 2, limit: [0, 1], with_scores: true)
      assert_equal [["s3", 3.0]], r.zrevrangebyscore("foo", 4, 2, limit: [1, 1], with_scores: true)
      assert_equal [["s4", 4.0]], r.zrevrangebyscore("foo", 4, 2, limit: [0, 1], withscores: true)
      assert_equal [["s3", 3.0]], r.zrevrangebyscore("foo", 4, 2, limit: [1, 1], withscores: true)

      r.zadd "bar", "-inf", "s1"
      r.zadd "bar", "+inf", "s2"
      assert_equal [["s2", +Float::INFINITY]], r.zrevrangebyscore("bar", +Float::INFINITY, -Float::INFINITY, limit: [0, 1], with_scores: true)
      assert_equal [["s1", -Float::INFINITY]], r.zrevrangebyscore("bar", +Float::INFINITY, -Float::INFINITY, limit: [1, 1], with_scores: true)
      assert_equal [["s2", +Float::INFINITY]], r.zrevrangebyscore("bar", +Float::INFINITY, -Float::INFINITY, limit: [0, 1], withscores: true)
      assert_equal [["s1", -Float::INFINITY]], r.zrevrangebyscore("bar", +Float::INFINITY, -Float::INFINITY, limit: [1, 1], withscores: true)
    end

    def test_zcard
      assert_equal 0, r.zcard("foo")

      r.zadd "foo", 1, "s1"

      assert_equal 1, r.zcard("foo")
    end

    def test_zscore
      r.zadd "foo", 1, "s1"

      assert_equal 1.0, r.zscore("foo", "s1")

      assert_nil r.zscore("foo", "s2")
      assert_nil r.zscore("bar", "s1")

      r.zadd "bar", "-inf", "s1"
      r.zadd "bar", "+inf", "s2"
      assert_equal(-Float::INFINITY, r.zscore("bar", "s1"))
      assert_equal(+Float::INFINITY, r.zscore("bar", "s2"))
    end

    def test_zmscore
      target_version("6.2") do
        r.zadd "foo", 1, "s1"

        assert_equal [1.0], r.zmscore("foo", "s1")
        assert_equal [nil], r.zmscore("foo", "s2")

        r.zadd "foo", "-inf", "s2"
        r.zadd "foo", "+inf", "s3"
        assert_equal [1.0, nil], r.zmscore("foo", "s1", "s4")
        assert_equal [-Float::INFINITY, +Float::INFINITY], r.zmscore("foo", "s2", "s3")
      end
    end

    def test_zrandmember
      target_version("6.2") do
        assert_nil r.zrandmember("foo")

        r.zadd "foo", 1.0, "s1"
        r.zrem "foo", "s1"
        assert_nil r.zrandmember("foo")
        assert_equal [], r.zrandmember("foo", 1)

        r.zadd "foo", 1.0, "s1"
        r.zadd "foo", 2.0, "s2"
        r.zadd "foo", 3.0, "s3"

        3.times do
          assert ["s1", "s2", "s3"].include?(r.zrandmember("foo"))
        end

        assert_equal 2, r.zrandmember("foo", 2).size
        assert_equal 3, r.zrandmember("foo", 4).size
        assert_equal 5, r.zrandmember("foo", -5).size

        r.zrandmember("foo", 2, with_scores: true).each do |(member, score)|
          assert ["s1", "s2", "s3"].include?(member)
          assert_instance_of Float, score
        end
      end
    end

    def test_zremrangebyrank
      r.zadd "foo", 10, "s1"
      r.zadd "foo", 20, "s2"
      r.zadd "foo", 30, "s3"
      r.zadd "foo", 40, "s4"

      assert_equal 3, r.zremrangebyrank("foo", 1, 3)
      assert_equal ["s1"], r.zrange("foo", 0, -1)
    end

    def test_zremrangebyscore
      r.zadd "foo", 1, "s1"
      r.zadd "foo", 2, "s2"
      r.zadd "foo", 3, "s3"
      r.zadd "foo", 4, "s4"

      assert_equal 3, r.zremrangebyscore("foo", 2, 4)
      assert_equal ["s1"], r.zrange("foo", 0, -1)
    end

    def test_zpopmax
      target_version('5.0.0') do
        r.zadd('foo', %w[0 a 1 b 2 c 3 d])
        assert_equal ['d', 3.0], r.zpopmax('foo')
        assert_equal [['c', 2.0], ['b', 1.0]], r.zpopmax('foo', 2)
        assert_equal [['a', 0.0]], r.zrange('foo', 0, -1, with_scores: true)
      end
    end

    def test_zpopmin
      target_version('5.0.0') do
        r.zadd('foo', %w[0 a 1 b 2 c 3 d])
        assert_equal ['a', 0.0], r.zpopmin('foo')
        assert_equal [['b', 1.0], ['c', 2.0]], r.zpopmin('foo', 2)
        assert_equal [['d', 3.0]], r.zrange('foo', 0, -1, with_scores: true)
      end
    end

    def test_zremrangebylex
      r.zadd('foo', %w[0 a 0 b 0 c 0 d 0 e 0 f 0 g])
      assert_equal 5, r.zremrangebylex('foo', '(b', '[g')
    end

    def test_zlexcount
      target_version '2.8.9' do
        r.zadd 'foo', 0, 'aaren'
        r.zadd 'foo', 0, 'abagael'
        r.zadd 'foo', 0, 'abby'
        r.zadd 'foo', 0, 'abbygail'

        assert_equal 4, r.zlexcount('foo', '[a', "[a\xff")
        assert_equal 4, r.zlexcount('foo', '[aa', "[ab\xff")
        assert_equal 3, r.zlexcount('foo', '(aaren', "[ab\xff")
        assert_equal 2, r.zlexcount('foo', '[aba', '(abbygail')
        assert_equal 1, r.zlexcount('foo', '(aaren', '(abby')
      end
    end

    def test_zrangebylex
      target_version '2.8.9' do
        r.zadd 'foo', 0, 'aaren'
        r.zadd 'foo', 0, 'abagael'
        r.zadd 'foo', 0, 'abby'
        r.zadd 'foo', 0, 'abbygail'

        assert_equal %w[aaren abagael abby abbygail], r.zrangebylex('foo', '[a', "[a\xff")
        assert_equal %w[aaren abagael], r.zrangebylex('foo', '[a', "[a\xff", limit: [0, 2])
        assert_equal %w[abby abbygail], r.zrangebylex('foo', '(abb', "(abb\xff")
        assert_equal %w[abbygail], r.zrangebylex('foo', '(abby', "(abby\xff")
      end
    end

    def test_zrevrangebylex
      target_version '2.9.9' do
        r.zadd 'foo', 0, 'aaren'
        r.zadd 'foo', 0, 'abagael'
        r.zadd 'foo', 0, 'abby'
        r.zadd 'foo', 0, 'abbygail'

        assert_equal %w[abbygail abby abagael aaren], r.zrevrangebylex('foo', "[a\xff", '[a')
        assert_equal %w[abbygail abby], r.zrevrangebylex('foo', "[a\xff", '[a', limit: [0, 2])
        assert_equal %w[abbygail abby], r.zrevrangebylex('foo', "(abb\xff", '(abb')
        assert_equal %w[abbygail], r.zrevrangebylex('foo', "(abby\xff", '(abby')
      end
    end

    def test_zcount
      r.zadd 'foo', 1, 's1'
      r.zadd 'foo', 2, 's2'
      r.zadd 'foo', 3, 's3'

      assert_equal 2, r.zcount('foo', 2, 3)
    end

    def test_zunion
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 2, 's2'
        r.zadd 'bar', 3, 's1'
        r.zadd 'bar', 5, 's3'

        assert_equal %w[s2 s1 s3], r.zunion('foo', 'bar')
        assert_equal [['s2', 2.0], ['s1', 4.0], ['s3', 5.0]], r.zunion('foo', 'bar', with_scores: true)
      end
    end

    def test_zunion_with_weights
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 2, 's2'
        r.zadd 'foo', 3, 's3'
        r.zadd 'bar', 20, 's2'
        r.zadd 'bar', 30, 's3'
        r.zadd 'bar', 100, 's4'

        assert_equal %w[s1 s2 s3 s4], r.zunion('foo', 'bar')
        assert_equal [['s1', 1.0], ['s2', 22.0], ['s3', 33.0], ['s4', 100.0]], r.zunion('foo', 'bar', with_scores: true)

        assert_equal %w[s1 s2 s3 s4], r.zunion('foo', 'bar', weights: [10, 1])
        assert_equal [['s1', 10.0], ['s2', 40.0], ['s3', 60.0], ['s4', 100.0]], r.zunion('foo', 'bar', weights: [10, 1], with_scores: true)
      end
    end

    def test_zunion_with_aggregate
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 20, 's2'
        r.zadd 'foo', 3, 's3'
        r.zadd 'bar', 2, 's2'
        r.zadd 'bar', 30, 's3'
        r.zadd 'bar', 100, 's4'

        assert_equal %w[s1 s2 s3 s4], r.zunion('foo', 'bar', aggregate: :min)
        assert_equal [['s1', 1.0], ['s2', 2.0], ['s3', 3.0], ['s4', 100.0]], r.zunion('foo', 'bar', aggregate: :min, with_scores: true)

        assert_equal %w[s1 s2 s3 s4], r.zunion('foo', 'bar', aggregate: :max)
        assert_equal [['s1', 1.0], ['s2', 20.0], ['s3', 30.0], ['s4', 100.0]], r.zunion('foo', 'bar', aggregate: :max, with_scores: true)
      end
    end

    def test_zunionstore
      r.zadd 'foo', 1, 's1'
      r.zadd 'bar', 2, 's2'
      r.zadd 'foo', 3, 's3'
      r.zadd 'bar', 4, 's4'

      assert_equal 4, r.zunionstore('foobar', %w[foo bar])
      assert_equal %w[s1 s2 s3 s4], r.zrange('foobar', 0, -1)
    end

    def test_zunionstore_with_weights
      r.zadd 'foo', 1, 's1'
      r.zadd 'foo', 3, 's3'
      r.zadd 'bar', 20, 's2'
      r.zadd 'bar', 40, 's4'

      assert_equal 4, r.zunionstore('foobar', %w[foo bar])
      assert_equal %w[s1 s3 s2 s4], r.zrange('foobar', 0, -1)

      assert_equal 4, r.zunionstore('foobar', %w[foo bar], weights: [10, 1])
      assert_equal %w[s1 s2 s3 s4], r.zrange('foobar', 0, -1)
    end

    def test_zunionstore_with_aggregate
      r.zadd 'foo', 1, 's1'
      r.zadd 'foo', 2, 's2'
      r.zadd 'bar', 4, 's2'
      r.zadd 'bar', 3, 's3'

      assert_equal 3, r.zunionstore('foobar', %w[foo bar])
      assert_equal %w[s1 s3 s2], r.zrange('foobar', 0, -1)

      assert_equal 3, r.zunionstore('foobar', %w[foo bar], aggregate: :min)
      assert_equal %w[s1 s2 s3], r.zrange('foobar', 0, -1)

      assert_equal 3, r.zunionstore('foobar', %w[foo bar], aggregate: :max)
      assert_equal %w[s1 s3 s2], r.zrange('foobar', 0, -1)
    end

    def test_zunionstore_expand
      r.zadd('{1}foo', %w[0 a 1 b 2 c])
      r.zadd('{1}bar', %w[0 c 1 d 2 e])
      assert_equal 5, r.zunionstore('{1}baz', %w[{1}foo {1}bar])
    end

    def test_zdiff
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 2, 's2'
        r.zadd 'bar', 3, 's1'
        r.zadd 'bar', 5, 's3'

        assert_equal [], r.zdiff('foo', 'foo')
        assert_equal ['s1', 's2'], r.zdiff('foo')

        assert_equal ['s2'], r.zdiff('foo', 'bar')
        assert_equal [['s2', 2.0]], r.zdiff('foo', 'bar', with_scores: true)
      end
    end

    def test_zdiffstore
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 2, 's2'
        r.zadd 'bar', 3, 's1'
        r.zadd 'bar', 5, 's3'

        assert_equal 0, r.zdiffstore('baz', ['foo', 'foo'])
        assert_equal 2, r.zdiffstore('baz', ['foo'])
        assert_equal ['s1', 's2'], r.zrange('baz', 0, -1)

        assert_equal 1, r.zdiffstore('baz', ['foo', 'bar'])
        assert_equal ['s2'], r.zrange('baz', 0, -1)
      end
    end

    def test_zinter
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'bar', 2, 's1'
        r.zadd 'foo', 3, 's3'
        r.zadd 'bar', 4, 's4'

        assert_equal ['s1'], r.zinter('foo', 'bar')
        assert_equal [['s1', 3.0]], r.zinter('foo', 'bar', with_scores: true)
      end
    end

    def test_zinter_with_weights
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 2, 's2'
        r.zadd 'foo', 3, 's3'
        r.zadd 'bar', 20, 's2'
        r.zadd 'bar', 30, 's3'
        r.zadd 'bar', 40, 's4'

        assert_equal %w[s2 s3], r.zinter('foo', 'bar')
        assert_equal [['s2', 22.0], ['s3', 33.0]], r.zinter('foo', 'bar', with_scores: true)

        assert_equal %w[s2 s3], r.zinter('foo', 'bar', weights: [10, 1])
        assert_equal [['s2', 40.0], ['s3', 60.0]], r.zinter('foo', 'bar', weights: [10, 1], with_scores: true)
      end
    end

    def test_zinter_with_aggregate
      target_version("6.2") do
        r.zadd 'foo', 1, 's1'
        r.zadd 'foo', 2, 's2'
        r.zadd 'foo', 3, 's3'
        r.zadd 'bar', 20, 's2'
        r.zadd 'bar', 30, 's3'
        r.zadd 'bar', 40, 's4'

        assert_equal %w[s2 s3], r.zinter('foo', 'bar')
        assert_equal [['s2', 22.0], ['s3', 33.0]], r.zinter('foo', 'bar', with_scores: true)

        assert_equal %w[s2 s3], r.zinter('foo', 'bar', aggregate: :min)
        assert_equal [['s2', 2.0], ['s3', 3.0]], r.zinter('foo', 'bar', aggregate: :min, with_scores: true)

        assert_equal %w[s2 s3], r.zinter('foo', 'bar', aggregate: :max)
        assert_equal [['s2', 20.0], ['s3', 30.0]], r.zinter('foo', 'bar', aggregate: :max, with_scores: true)
      end
    end

    def test_zinterstore
      r.zadd 'foo', 1, 's1'
      r.zadd 'bar', 2, 's1'
      r.zadd 'foo', 3, 's3'
      r.zadd 'bar', 4, 's4'

      assert_equal 1, r.zinterstore('foobar', %w[foo bar])
      assert_equal ['s1'], r.zrange('foobar', 0, -1)
    end

    def test_zinterstore_with_weights
      r.zadd 'foo', 1, 's1'
      r.zadd 'foo', 2, 's2'
      r.zadd 'foo', 3, 's3'
      r.zadd 'bar', 20, 's2'
      r.zadd 'bar', 30, 's3'
      r.zadd 'bar', 40, 's4'

      assert_equal 2, r.zinterstore('foobar', %w[foo bar])
      assert_equal %w[s2 s3], r.zrange('foobar', 0, -1)

      assert_equal 2, r.zinterstore('foobar', %w[foo bar], weights: [10, 1])
      assert_equal %w[s2 s3], r.zrange('foobar', 0, -1)

      assert_equal 40.0, r.zscore('foobar', 's2')
      assert_equal 60.0, r.zscore('foobar', 's3')
    end

    def test_zinterstore_with_aggregate
      r.zadd 'foo', 1, 's1'
      r.zadd 'foo', 2, 's2'
      r.zadd 'foo', 3, 's3'
      r.zadd 'bar', 20, 's2'
      r.zadd 'bar', 30, 's3'
      r.zadd 'bar', 40, 's4'

      assert_equal 2, r.zinterstore('foobar', %w[foo bar])
      assert_equal %w[s2 s3], r.zrange('foobar', 0, -1)
      assert_equal 22.0, r.zscore('foobar', 's2')
      assert_equal 33.0, r.zscore('foobar', 's3')

      assert_equal 2, r.zinterstore('foobar', %w[foo bar], aggregate: :min)
      assert_equal %w[s2 s3], r.zrange('foobar', 0, -1)
      assert_equal 2.0, r.zscore('foobar', 's2')
      assert_equal 3.0, r.zscore('foobar', 's3')

      assert_equal 2, r.zinterstore('foobar', %w[foo bar], aggregate: :max)
      assert_equal %w[s2 s3], r.zrange('foobar', 0, -1)
      assert_equal 20.0, r.zscore('foobar', 's2')
      assert_equal 30.0, r.zscore('foobar', 's3')
    end

    def test_zinterstore_expand
      r.zadd '{1}foo', %w[0 s1 1 s2 2 s3]
      r.zadd '{1}bar', %w[0 s3 1 s4 2 s5]
      assert_equal 1, r.zinterstore('{1}baz', %w[{1}foo {1}bar], weights: [2.0, 3.0])
    end

    def test_zscan
      r.zadd('foo', %w[0 a 1 b 2 c])
      expected = ['0', [['a', 0.0], ['b', 1.0], ['c', 2.0]]]
      assert_equal expected, r.zscan('foo', 0)
    end
  end
end
