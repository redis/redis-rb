module Lint

  module Sets

    def test_sadd
      assert_equal true, r.sadd("foo", "s1")
      assert_equal true, r.sadd("foo", "s2")
      assert_equal false, r.sadd("foo", "s1")

      assert_equal ["s1", "s2"], r.smembers("foo").sort
    end

    def test_variadic_sadd
      return if version < 203090 # 2.4-rc6

      assert_equal 2, r.sadd("foo", ["s1", "s2"])
      assert_equal 1, r.sadd("foo", ["s1", "s2", "s3"])

      assert_equal ["s1", "s2", "s3"], r.smembers("foo").sort
    end

    def test_srem
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")

      assert_equal true, r.srem("foo", "s1")
      assert_equal false, r.srem("foo", "s3")

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_variadic_srem
      return if version < 203090 # 2.4-rc6

      r.sadd("foo", "s1")
      r.sadd("foo", "s2")
      r.sadd("foo", "s3")

      assert_equal 1, r.srem("foo", ["s1", "aaa"])
      assert_equal 0, r.srem("foo", ["bbb", "ccc" "ddd"])
      assert_equal 1, r.srem("foo", ["eee", "s3"])

      assert_equal ["s2"], r.smembers("foo")
    end

    def test_spop
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      assert ["s1", "s2"].include?(r.spop("foo"))
      assert ["s1", "s2"].include?(r.spop("foo"))
      assert_equal nil, r.spop("foo")
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
  end
end
