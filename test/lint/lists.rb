module Lint

  module Lists

    def test_rpush
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert 2 == r.llen("foo")
      assert "s2" == r.rpop("foo")
    end

    def test_variadic_rpush
      return if version < 203090 # 2.4-rc6

      assert 3 == r.rpush("foo", ["s1", "s2", "s3"])
      assert 3 == r.llen("foo")
      assert "s3" == r.rpop("foo")
    end

    def test_lpush
      r.lpush "foo", "s1"
      r.lpush "foo", "s2"

      assert 2 == r.llen("foo")
      assert "s2" == r.lpop("foo")
    end

    def test_variadic_lpush
      return if version < 203090 # 2.4-rc6

      assert 3 == r.lpush("foo", ["s1", "s2", "s3"])
      assert 3 == r.llen("foo")
      assert "s3" == r.lpop("foo")
    end

    def test_llen
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert 2 == r.llen("foo")
    end

    def test_lrange
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"
      r.rpush "foo", "s3"

      assert ["s2", "s3"] == r.lrange("foo", 1, -1)
      assert ["s1", "s2"] == r.lrange("foo", 0, 1)

      assert [] == r.lrange("bar", 0, -1)
    end

    def test_ltrim
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"
      r.rpush "foo", "s3"

      r.ltrim "foo", 0, 1

      assert 2 == r.llen("foo")
      assert ["s1", "s2"] == r.lrange("foo", 0, -1)
    end

    def test_lindex
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert "s1" == r.lindex("foo", 0)
      assert "s2" == r.lindex("foo", 1)
    end

    def test_lset
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert "s2" == r.lindex("foo", 1)
      assert r.lset("foo", 1, "s3")
      assert "s3" == r.lindex("foo", 1)

      assert_raise Redis::CommandError do
        r.lset("foo", 4, "s3")
      end
    end

    def test_lrem
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert 1 == r.lrem("foo", 1, "s1")
      assert ["s2"] == r.lrange("foo", 0, -1)
    end

    def test_lpop
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert 2 == r.llen("foo")
      assert "s1" == r.lpop("foo")
      assert 1 == r.llen("foo")
    end

    def test_rpop
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert 2 == r.llen("foo")
      assert "s2" == r.rpop("foo")
      assert 1 == r.llen("foo")
    end
  end
end
