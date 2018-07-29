module Lint

  module Sets

    def test_sadd
      assert_equal true, r.sadd("foo", "s1")
      assert_equal true, r.sadd("foo", "s2")
      assert_equal false, r.sadd("foo", "s1")

      assert_equal ["s1", "s2"], r.smembers("foo").sort
    end

    def test_variadic_sadd
      target_version "2.3.9" do # 2.4-rc6
        assert_equal 2, r.sadd("foo", ["s1", "s2"])
        assert_equal 1, r.sadd("foo", ["s1", "s2", "s3"])

        assert_equal ["s1", "s2", "s3"], r.smembers("foo").sort
      end
    end

    def test_srem
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")

      assert_equal true, r.srem("foo", "s1")
      assert_equal false, r.srem("foo", "s3")

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_variadic_srem
      target_version "2.3.9" do # 2.4-rc6
        r.sadd("foo", "s1")
        r.sadd("foo", "s2")
        r.sadd("foo", "s3")

        assert_equal 1, r.srem("foo", ["s1", "aaa"])
        assert_equal 0, r.srem("foo", ["bbb", "ccc" "ddd"])
        assert_equal 1, r.srem("foo", ["eee", "s3"])

        assert_equal ["s2"], r.smembers("foo")
      end
    end

    def test_spop
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      assert ["s1", "s2"].include?(r.spop("foo"))
      assert ["s1", "s2"].include?(r.spop("foo"))
      assert_equal nil, r.spop("foo")
    end

    def test_spop_with_positive_count
      target_version "3.2.0" do
        r.sadd "foo", "s1"
        r.sadd "foo", "s2"
        r.sadd "foo", "s3"
        r.sadd "foo", "s4"

        pops = r.spop("foo", 3)

        assert !(["s1", "s2", "s3", "s4"] & pops).empty?
        assert_equal 3, pops.size
        assert_equal 1, r.scard("foo")
      end
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

    def test_sscan
      r.sadd('foo', %w[1 2 3 foo foobar feelsgood])
      assert_equal %w[0 feelsgood foo foobar], r.sscan('foo', 0, match: 'f*').flatten.sort
    end
  end
end
