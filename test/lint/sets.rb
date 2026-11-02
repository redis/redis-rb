# frozen_string_literal: true

module Lint
  module Sets
    def test_sadd
      assert_equal 1, r.sadd("foo", "s1")
      assert_equal 1, r.sadd("foo", "s2")
      assert_equal 0, r.sadd("foo", "s1")

      assert_equal ["s1", "s2"], r.smembers("foo").sort
    end

    def test_sadd?
      assert_equal true, r.sadd?("foo", "s1")
      assert_equal true, r.sadd?("foo", "s2")
      assert_equal false, r.sadd?("foo", "s1")

      assert_equal ["s1", "s2"], r.smembers("foo").sort
    end

    def test_variadic_sadd
      assert_equal 2, r.sadd("foo", ["s1", "s2"])
      assert_equal 1, r.sadd("foo", ["s1", "s2", "s3"])

      assert_equal ["s1", "s2", "s3"], r.smembers("foo").sort
    end

    def test_variadic_sadd?
      assert_equal true, r.sadd?("foo", ["s1", "s2"])
      assert_equal true, r.sadd?("foo", ["s1", "s2", "s3"])
      assert_equal false, r.sadd?("foo", ["s1", "s2"])

      assert_equal ["s1", "s2", "s3"], r.smembers("foo").sort
    end

    def test_srem
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")

      assert_equal 1, r.srem("foo", "s1")
      assert_equal 0, r.srem("foo", "s3")

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_srem?
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")

      assert_equal true, r.srem?("foo", "s1")
      assert_equal false, r.srem?("foo", "s3")

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_variadic_srem
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")
      r.sadd("foo", "s3")

      assert_equal 1, r.srem("foo", ["s1", "aaa"])
      assert_equal 0, r.srem("foo", ["bbb", "ccc", "ddd"])
      assert_equal 1, r.srem("foo", ["eee", "s3"])

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_variadic_srem?
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")
      r.sadd("foo", "s3")

      assert_equal true, r.srem?("foo", ["s1", "aaa"])
      assert_equal false, r.srem?("foo", ["bbb", "ccc", "ddd"])
      assert_equal true, r.srem?("foo", "eee", "s3")

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_spop
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      assert ["s1", "s2"].include?(r.spop("foo"))
      assert ["s1", "s2"].include?(r.spop("foo"))
      assert_nil r.spop("foo")
    end

    def test_spop_with_positive_count
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "foo", "s3"
      r.sadd "foo", "s4"

      pops = r.spop("foo", 3)

      assert !(["s1", "s2", "s3", "s4"] & pops).empty?
      assert_equal 3, pops.size
      assert_equal 1, r.scard("foo")
    end

    def test_scard
      assert_equal 0, r.scard("foo")

      r.sadd "foo", "s1"

      assert_equal 1, r.scard("foo")

      r.sadd "foo", "s2"

      assert_equal 2, r.scard("foo")
    end

    def test_sismember
      assert_equal false, r.sismember("foo", "s1")

      r.sadd "foo", "s1"

      assert_equal true,  r.sismember("foo", "s1")
      assert_equal false, r.sismember("foo", "s2")
    end

    def test_smismember
      target_version("6.2") do
        assert_equal [false], r.smismember("foo", "s1")

        r.sadd "foo", "s1"
        assert_equal [true], r.smismember("foo", "s1")

        r.sadd "foo", "s3"
        assert_equal [true, false, true], r.smismember("foo", "s1", "s2", "s3")
      end
    end

    def test_smembers
      assert_equal [], r.smembers("foo")

      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      assert_equal ["s1", "s2"], r.smembers("foo").sort
    end

    def test_srandmember
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      4.times do
        assert ["s1", "s2"].include?(r.srandmember("foo"))
      end

      assert_equal 2, r.scard("foo")
    end

    def test_srandmember_with_positive_count
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "foo", "s3"
      r.sadd "foo", "s4"

      4.times do
        assert !(["s1", "s2", "s3", "s4"] & r.srandmember("foo", 3)).empty?

        assert_equal 3, r.srandmember("foo", 3).size
      end

      assert_equal 4, r.scard("foo")
    end

    def test_srandmember_with_negative_count
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"
      r.sadd "foo", "s3"
      r.sadd "foo", "s4"

      4.times do
        assert !(["s1", "s2", "s3", "s4"] & r.srandmember("foo", -6)).empty?
        assert_equal 6, r.srandmember("foo", -6).size
      end

      assert_equal 4, r.scard("foo")
    end

    def test_smove
      r.sadd 'foo', 's1'
      r.sadd 'bar', 's2'

      assert r.smove('foo', 'bar', 's1')
      assert r.sismember('bar', 's1')
    end

    def test_sinter
      r.sadd 'foo', 's1'
      r.sadd 'foo', 's2'
      r.sadd 'bar', 's2'

      assert_equal ['s2'], r.sinter('foo', 'bar')
    end

    def test_variadic_smove_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal true, r.smove('{1}foo', '{1}bar', 's2')
    end

    def test_variadic_sinter_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal %w[s3], r.sinter('{1}foo', '{1}bar')
    end

    def test_sinterstore
      r.sadd 'foo', 's1'
      r.sadd 'foo', 's2'
      r.sadd 'bar', 's2'

      r.sinterstore('baz', 'foo', 'bar')

      assert_equal ['s2'], r.smembers('baz')
    end

    def test_variadic_sinterstore_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal 1, r.sinterstore('{1}baz', '{1}foo', '{1}bar')
    end

    def test_sunion
      r.sadd 'foo', 's1'
      r.sadd 'foo', 's2'
      r.sadd 'bar', 's2'
      r.sadd 'bar', 's3'

      assert_equal %w[s1 s2 s3], r.sunion('foo', 'bar').sort
    end

    def test_variadic_sunion_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal %w[s1 s2 s3 s4 s5], r.sunion('{1}foo', '{1}bar').sort
    end

    def test_sunionstore
      r.sadd 'foo', 's1'
      r.sadd 'foo', 's2'
      r.sadd 'bar', 's2'
      r.sadd 'bar', 's3'

      r.sunionstore('baz', 'foo', 'bar')

      assert_equal %w[s1 s2 s3], r.smembers('baz').sort
    end

    def test_variadic_sunionstore_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal 5, r.sunionstore('{1}baz', '{1}foo', '{1}bar')
    end

    def test_sdiff
      r.sadd 'foo', 's1'
      r.sadd 'foo', 's2'
      r.sadd 'bar', 's2'
      r.sadd 'bar', 's3'

      assert_equal ['s1'], r.sdiff('foo', 'bar')
      assert_equal ['s3'], r.sdiff('bar', 'foo')
    end

    def test_variadic_sdiff_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal %w[s1 s2], r.sdiff('{1}foo', '{1}bar').sort
    end

    def test_sdiffstore
      r.sadd 'foo', 's1'
      r.sadd 'foo', 's2'
      r.sadd 'bar', 's2'
      r.sadd 'bar', 's3'

      r.sdiffstore('baz', 'foo', 'bar')

      assert_equal ['s1'], r.smembers('baz')
    end

    def test_variadic_sdiffstore_expand
      r.sadd('{1}foo', 's1')
      r.sadd('{1}foo', 's2')
      r.sadd('{1}foo', 's3')
      r.sadd('{1}bar', 's3')
      r.sadd('{1}bar', 's4')
      r.sadd('{1}bar', 's5')
      assert_equal 2, r.sdiffstore('{1}baz', '{1}foo', '{1}bar')
    end

    def test_sdiffcard
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3 s4 s5])
        r.sadd('{1}bar', %w[s3 s4])
        r.sadd('{1}baz', 's5')

        assert_equal 2, r.sdiffcard('{1}foo', '{1}bar', '{1}baz')
        assert_equal 0, r.sdiffcard('{1}bar', '{1}foo')
      end
    end

    def test_sdiffcard_with_single_key
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3])

        assert_equal 3, r.sdiffcard('{1}foo')
        assert_equal 0, r.sdiffcard('{1}nonexistent')
      end
    end

    def test_variadic_sdiffcard_expand
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3])
        r.sadd('{1}bar', 's3')

        assert_equal 2, r.sdiffcard(['{1}foo', '{1}bar'])
      end
    end

    def test_sdiffcard_with_limit
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3 s4])
        r.sadd('{1}bar', 's4')

        assert_equal 2, r.sdiffcard('{1}foo', '{1}bar', limit: 2)
        assert_equal 3, r.sdiffcard('{1}foo', '{1}bar', limit: 0)
      end
    end

    def test_sunioncard
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3])
        r.sadd('{1}bar', %w[s3 s4])

        assert_equal 4, r.sunioncard('{1}foo', '{1}bar')
      end
    end

    def test_sunioncard_with_single_key
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3])

        assert_equal 3, r.sunioncard('{1}foo')
        assert_equal 0, r.sunioncard('{1}nonexistent')
      end
    end

    def test_variadic_sunioncard_expand
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2])
        r.sadd('{1}bar', %w[s2 s3])

        assert_equal 3, r.sunioncard(['{1}foo', '{1}bar'])
      end
    end

    def test_sunioncard_with_approx
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3])
        r.sadd('{1}bar', %w[s3 s4])

        assert_equal r.sunioncard('{1}foo', '{1}bar'),
                     r.sunioncard('{1}foo', '{1}bar', approx: true)
      end
    end

    def test_sunioncard_with_limit
      target_version('8.10') do
        r.sadd('{1}foo', %w[s1 s2 s3])
        r.sadd('{1}bar', %w[s3 s4])

        assert_equal 2, r.sunioncard('{1}foo', '{1}bar', limit: 2)
        assert_equal 4, r.sunioncard('{1}foo', '{1}bar', limit: 0)
        assert_equal 2, r.sunioncard('{1}foo', '{1}bar', approx: true, limit: 2)
      end
    end

    def test_sintercard
      target_version('7.0.0') do
        r.sadd('{1}foo', %w[s1 s2 s3 s4])
        r.sadd('{1}bar', %w[s2 s3 s4 s5])
        r.sadd('{1}baz', %w[s3 s4 s6])

        assert_equal 3, r.sintercard('{1}foo', '{1}bar')
        assert_equal 2, r.sintercard('{1}foo', '{1}bar', '{1}baz')
      end
    end

    def test_sintercard_with_single_key
      target_version('7.0.0') do
        r.sadd('{1}foo', %w[s1 s2 s3])

        assert_equal 3, r.sintercard('{1}foo')
        assert_equal 0, r.sintercard('{1}nonexistent')
      end
    end

    def test_sintercard_with_missing_key
      target_version('7.0.0') do
        r.sadd('{1}foo', %w[s1 s2 s3])

        assert_equal 0, r.sintercard('{1}foo', '{1}nonexistent')
      end
    end

    def test_variadic_sintercard_expand
      target_version('7.0.0') do
        r.sadd('{1}foo', %w[s1 s2 s3])
        r.sadd('{1}bar', %w[s2 s3])

        assert_equal 2, r.sintercard(['{1}foo', '{1}bar'])
      end
    end

    def test_sintercard_with_limit
      target_version('7.0.0') do
        r.sadd('{1}foo', %w[s1 s2 s3 s4])
        r.sadd('{1}bar', %w[s2 s3 s4])

        assert_equal 1, r.sintercard('{1}foo', '{1}bar', limit: 1)
        assert_equal 3, r.sintercard('{1}foo', '{1}bar', limit: 0)
        assert_equal 3, r.sintercard('{1}foo', '{1}bar', limit: 10)
      end
    end

    def test_sscan
      r.sadd('foo', %w[1 2 3 foo foobar feelsgood])
      assert_equal %w[0 feelsgood foo foobar], r.sscan('foo', 0, match: 'f*').flatten.sort
    end

    def test_sexpire
      target_version("8.11") do
        r.sadd("foo", "m1")

        assert_equal [1, -2], r.sexpire("foo", 4, "m1", "m2")
        assert_in_range(1..4, r.sttl("foo", "m1")[0])
        assert_equal [-2], r.sexpire("nonexistent", 4, "m1")
      end
    end

    def test_sexpire_with_zero_ttl
      target_version("8.11") do
        r.sadd("foo", %w[m1 m2])

        assert_equal [2], r.sexpire("foo", 0, ["m1"])
        assert_equal ["m2"], r.smembers("foo")
      end
    end

    def test_sexpire_options
      target_version("8.11") do
        r.sadd("foo", "m1")
        assert_equal [0], r.sexpire("foo", 5_000, "m1", xx: true)

        assert_equal [1], r.sexpire("foo", 5_000, "m1", nx: true)
        assert_equal [0], r.sexpire("foo", 5_000, "m1", nx: true)

        assert_equal [1], r.sexpire("foo", 5_000, "m1", xx: true)

        assert_equal [0], r.sexpire("foo", 50_000, "m1", lt: true)
        assert_equal [1], r.sexpire("foo", 500, "m1", lt: true)

        assert_equal [0], r.sexpire("foo", 400, "m1", gt: true)
        assert_equal [1], r.sexpire("foo", 50_000, "m1", gt: true)
      end
    end

    def test_sexpire_with_multiple_conditions
      assert_raises(ArgumentError) { r.sexpire("foo", 10, "m1", nx: true, xx: true) }
    end

    def test_sexpire_with_wrong_type
      target_version("8.11") do
        r.set("foo", "bar")

        assert_raises(Redis::WrongTypeError) { r.sexpire("foo", 10, "m1") }
      end
    end

    def test_spexpire
      target_version("8.11") do
        r.sadd("foo", "m1")

        assert_equal [1, -2], r.spexpire("foo", 4_000, "m1", "m2")
        assert_in_range(1..4_000, r.spttl("foo", "m1")[0])
        assert_equal [-2], r.spexpire("nonexistent", 4_000, "m1")
      end
    end

    def test_spexpire_with_zero_ttl
      target_version("8.11") do
        r.sadd("foo", %w[m1 m2])

        assert_equal [2], r.spexpire("foo", 0, ["m1"])
        assert_equal ["m2"], r.smembers("foo")
      end
    end

    def test_spexpire_options
      target_version("8.11") do
        r.sadd("foo", "m1")
        assert_equal [0], r.spexpire("foo", 5_000_000, "m1", xx: true)

        assert_equal [1], r.spexpire("foo", 5_000_000, "m1", nx: true)
        assert_equal [0], r.spexpire("foo", 5_000_000, "m1", nx: true)

        assert_equal [1], r.spexpire("foo", 5_000_000, "m1", xx: true)

        assert_equal [0], r.spexpire("foo", 50_000_000, "m1", lt: true)
        assert_equal [1], r.spexpire("foo", 500_000, "m1", lt: true)

        assert_equal [0], r.spexpire("foo", 400_000, "m1", gt: true)
        assert_equal [1], r.spexpire("foo", 50_000_000, "m1", gt: true)
      end
    end

    def test_spexpire_with_multiple_conditions
      assert_raises(ArgumentError) { r.spexpire("foo", 10, "m1", gt: true, lt: true) }
    end

    def test_sexpireat
      target_version("8.11") do
        r.sadd("foo", "m1")

        assert_equal [1, -2], r.sexpireat("foo", Time.now.to_i + 400, "m1", "m2")
        assert_in_range(1..405, r.sttl("foo", "m1")[0])
        assert_equal [-2], r.sexpireat("nonexistent", Time.now.to_i + 400, "m1")
      end
    end

    def test_sexpireat_with_past_timestamp
      target_version("8.11") do
        r.sadd("foo", %w[m1 m2])

        assert_equal [2], r.sexpireat("foo", Time.now.to_i - 4, ["m1"])
        assert_equal ["m2"], r.smembers("foo")
      end
    end

    def test_sexpireat_options
      target_version("8.11") do
        now = Time.now.to_i

        r.sadd("foo", "m1")
        assert_equal [0], r.sexpireat("foo", now + 5_000, "m1", xx: true)

        assert_equal [1], r.sexpireat("foo", now + 5_000, "m1", nx: true)
        assert_equal [0], r.sexpireat("foo", now + 5_000, "m1", nx: true)

        assert_equal [1], r.sexpireat("foo", now + 5_000, "m1", xx: true)

        assert_equal [0], r.sexpireat("foo", now + 50_000, "m1", lt: true)
        assert_equal [1], r.sexpireat("foo", now + 500, "m1", lt: true)

        assert_equal [0], r.sexpireat("foo", now + 400, "m1", gt: true)
        assert_equal [1], r.sexpireat("foo", now + 50_000, "m1", gt: true)
      end
    end

    def test_sexpireat_with_multiple_conditions
      assert_raises(ArgumentError) { r.sexpireat("foo", Time.now.to_i + 10, "m1", nx: true, gt: true) }
    end

    def test_spexpireat
      target_version("8.11") do
        now_ms = (Time.now.to_f * 1000).to_i
        r.sadd("foo", "m1")

        assert_equal [1, -2], r.spexpireat("foo", now_ms + 400_000, "m1", "m2")
        assert_in_range(1..400_500, r.spttl("foo", "m1")[0])
        assert_equal [-2], r.spexpireat("nonexistent", now_ms + 400_000, "m1")
      end
    end

    def test_spexpireat_with_past_timestamp
      target_version("8.11") do
        r.sadd("foo", %w[m1 m2])

        assert_equal [2], r.spexpireat("foo", (Time.now.to_f * 1000).to_i - 4_000, ["m1"])
        assert_equal ["m2"], r.smembers("foo")
      end
    end

    def test_spexpireat_options
      target_version("8.11") do
        now_ms = (Time.now.to_f * 1000).to_i

        r.sadd("foo", "m1")
        assert_equal [0], r.spexpireat("foo", now_ms + 5_000_000, "m1", xx: true)

        assert_equal [1], r.spexpireat("foo", now_ms + 5_000_000, "m1", nx: true)
        assert_equal [0], r.spexpireat("foo", now_ms + 5_000_000, "m1", nx: true)

        assert_equal [1], r.spexpireat("foo", now_ms + 5_000_000, "m1", xx: true)

        assert_equal [0], r.spexpireat("foo", now_ms + 50_000_000, "m1", lt: true)
        assert_equal [1], r.spexpireat("foo", now_ms + 500_000, "m1", lt: true)

        assert_equal [0], r.spexpireat("foo", now_ms + 400_000, "m1", gt: true)
        assert_equal [1], r.spexpireat("foo", now_ms + 50_000_000, "m1", gt: true)
      end
    end

    def test_spexpireat_with_multiple_conditions
      assert_raises(ArgumentError) { r.spexpireat("foo", 10, "m1", xx: true, lt: true) }
    end

    def test_sttl
      target_version("8.11") do
        assert_equal [-2], r.sttl("foo", "m1")

        r.sadd("foo", %w[m1 m2])
        assert_equal [-1, -1], r.sttl("foo", ["m1", "m2"])

        r.sexpire("foo", 4, "m1")
        ttl, no_expiry, missing = r.sttl("foo", "m1", "m2", "m3")
        assert_in_range(1..4, ttl)
        assert_equal(-1, no_expiry)
        assert_equal(-2, missing)
      end
    end

    def test_spttl
      target_version("8.11") do
        assert_equal [-2], r.spttl("foo", "m1")

        r.sadd("foo", %w[m1 m2])
        assert_equal [-1, -1], r.spttl("foo", ["m1", "m2"])

        r.spexpire("foo", 4_000, "m1")
        ttl, no_expiry, missing = r.spttl("foo", "m1", "m2", "m3")
        assert_in_range(1..4_000, ttl)
        assert_equal(-1, no_expiry)
        assert_equal(-2, missing)
      end
    end

    def test_sexpiretime
      target_version("8.11") do
        assert_equal [-2], r.sexpiretime("foo", "m1")

        r.sadd("foo", %w[m1 m2])
        assert_equal [-1], r.sexpiretime("foo", "m1")

        expire_at = Time.now.to_i + 400
        r.sexpireat("foo", expire_at, "m1")
        assert_equal [expire_at, -1, -2], r.sexpiretime("foo", "m1", ["m2", "m3"])
      end
    end

    def test_spexpiretime
      target_version("8.11") do
        assert_equal [-2], r.spexpiretime("foo", "m1")

        r.sadd("foo", %w[m1 m2])
        assert_equal [-1], r.spexpiretime("foo", "m1")

        expire_at_ms = (Time.now.to_f * 1000).to_i + 400_000
        r.spexpireat("foo", expire_at_ms, "m1")
        assert_equal [expire_at_ms, -1, -2], r.spexpiretime("foo", "m1", ["m2", "m3"])
      end
    end

    def test_spersist
      target_version("8.11") do
        assert_equal [-2], r.spersist("foo", "m1")

        r.sadd("foo", %w[m1 m2])
        r.sexpire("foo", 400, "m1")

        assert_equal [1, -1, -2], r.spersist("foo", "m1", ["m2", "m3"])
        assert_equal [-1], r.sttl("foo", "m1")
      end
    end

    def test_saddex
      target_version("8.11") do
        assert_equal 1, r.saddex("foo", "m1", "m2")
        assert_equal ["m1", "m2"], r.smembers("foo").sort
        assert_equal [-1, -1], r.sttl("foo", "m1", "m2")

        # Applies the TTL to both the new and the already-present member.
        assert_equal 1, r.saddex("foo", ["m1", "m3"], ex: 100)
        ttl_m1, ttl_m2, ttl_m3 = r.sttl("foo", "m1", "m2", "m3")
        assert_in_range(1..100, ttl_m1)
        assert_equal(-1, ttl_m2)
        assert_in_range(1..100, ttl_m3)

        # Re-adding without an expiration option clears the TTL.
        assert_equal 1, r.saddex("foo", "m3")
        assert_equal [-1], r.sttl("foo", "m3")
      end
    end

    def test_saddex_expiration_options
      target_version("8.11") do
        assert_equal 1, r.saddex("foo", "m1", px: 5_000)
        assert_in_range(1..5_000, r.spttl("foo", "m1")[0])

        expire_at = Time.now.to_i + 400
        assert_equal 1, r.saddex("foo", "m2", exat: expire_at)
        assert_equal [expire_at], r.sexpiretime("foo", "m2")

        expire_at_ms = (Time.now.to_f * 1000).to_i + 400_000
        assert_equal 1, r.saddex("foo", "m3", pxat: expire_at_ms)
        assert_equal [expire_at_ms], r.spexpiretime("foo", "m3")

        r.saddex("foo", "m2", keepttl: true)
        assert_equal [expire_at], r.sexpiretime("foo", "m2")
      end
    end

    def test_saddex_conditions
      target_version("8.11") do
        r.sadd("foo", "m1")

        assert_equal 0, r.saddex("foo", "m1", "m2", mnx: true, ex: 100)
        assert_equal ["m1"], r.smembers("foo")
        assert_equal [-1], r.sttl("foo", "m1")
        assert_equal 1, r.saddex("foo", "m2", mnx: true, ex: 100)
        assert_in_range(1..100, r.sttl("foo", "m2")[0])

        assert_equal 0, r.saddex("foo", "m1", "m3", mxx: true, ex: 100)
        assert_equal [-1], r.sttl("foo", "m1")
        assert_equal 1, r.saddex("foo", "m1", mxx: true, ex: 100)
        assert_in_range(1..100, r.sttl("foo", "m1")[0])
      end
    end

    def test_saddex_with_conflicting_options
      assert_raises(ArgumentError) { r.saddex("foo", "m1", mnx: true, mxx: true) }
      assert_raises(ArgumentError) { r.saddex("foo", "m1", ex: 60, px: 60_000) }
      assert_raises(ArgumentError) { r.saddex("foo", "m1", ex: 60, keepttl: true) }
    end
  end
end
