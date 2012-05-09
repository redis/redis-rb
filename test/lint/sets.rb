module Lint

  module Sets

    def test_sadd
      assert true == r.sadd("foo", "s1")
      assert true == r.sadd("foo", "s2")
      assert false == r.sadd("foo", "s1")

      assert ["s1", "s2"] == r.smembers("foo").sort
    end

    def test_variadic_sadd
      return if version < 203090 # 2.4-rc6

      assert 2 == r.sadd("foo", ["s1", "s2"])
      assert 1 == r.sadd("foo", ["s1", "s2", "s3"])

      assert ["s1", "s2", "s3"] == r.smembers("foo").sort
    end

    def test_srem
      r.sadd("foo", "s1")
      r.sadd("foo", "s2")

      assert true == r.srem("foo", "s1")
      assert false == r.srem("foo", "s3")

      assert ["s2"] == r.smembers("foo")
    end

    def test_variadic_srem
      return if version < 203090 # 2.4-rc6

      r.sadd("foo", "s1")
      r.sadd("foo", "s2")
      r.sadd("foo", "s3")

      assert 1 == r.srem("foo", ["s1", "aaa"])
      assert 0 == r.srem("foo", ["bbb", "ccc" "ddd"])
      assert 1 == r.srem("foo", ["eee", "s3"])

      assert ["s2"] == r.smembers("foo")
    end

    def test_spop
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      assert ["s1", "s2"].include?(r.spop("foo"))
      assert ["s1", "s2"].include?(r.spop("foo"))
      assert nil == r.spop("foo")
    end

    def test_scard
      assert 0 == r.scard("foo")

      r.sadd "foo", "s1"

      assert 1 == r.scard("foo")

      r.sadd "foo", "s2"

      assert 2 == r.scard("foo")
    end

    def test_sismember
      assert false == r.sismember("foo", "s1")

      r.sadd "foo", "s1"

      assert true ==  r.sismember("foo", "s1")
      assert false == r.sismember("foo", "s2")
    end

    def test_smembers
      assert [] == r.smembers("foo")

      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      assert ["s1", "s2"] == r.smembers("foo").sort
    end

    def test_srandmember
      r.sadd "foo", "s1"
      r.sadd "foo", "s2"

      4.times do
        assert ["s1", "s2"].include?(r.srandmember("foo"))
      end

      assert 2 == r.scard("foo")
    end
  end
end
