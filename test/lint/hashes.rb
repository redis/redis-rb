module Lint

  module Hashes

    def test_hset_and_hget
      r.hset("foo", "f1", "s1")

      assert "s1" == r.hget("foo", "f1")
    end

    def test_hsetnx
      r.hset("foo", "f1", "s1")
      r.hsetnx("foo", "f1", "s2")

      assert "s1" == r.hget("foo", "f1")

      r.del("foo")
      r.hsetnx("foo", "f1", "s2")

      assert "s2" == r.hget("foo", "f1")
    end

    def test_hdel
      r.hset("foo", "f1", "s1")

      assert "s1" == r.hget("foo", "f1")

      assert 1 == r.hdel("foo", "f1")

      assert nil == r.hget("foo", "f1")
    end

    def test_variadic_hdel
      return if version < 203090

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert "s1" == r.hget("foo", "f1")
      assert "s2" == r.hget("foo", "f2")

      assert 2 == r.hdel("foo", ["f1", "f2"])

      assert nil == r.hget("foo", "f1")
      assert nil == r.hget("foo", "f2")
    end

    def test_hexists
      assert false == r.hexists("foo", "f1")

      r.hset("foo", "f1", "s1")

      assert r.hexists("foo", "f1")
    end

    def test_hlen
      assert 0 == r.hlen("foo")

      r.hset("foo", "f1", "s1")

      assert 1 == r.hlen("foo")

      r.hset("foo", "f2", "s2")

      assert 2 == r.hlen("foo")
    end

    def test_hkeys
      assert [] == r.hkeys("foo")

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert ["f1", "f2"] == r.hkeys("foo")
    end

    def test_hvals
      assert [] == r.hvals("foo")

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert ["s1", "s2"] == r.hvals("foo")
    end

    def test_hgetall
      assert({} == r.hgetall("foo"))

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert({"f1" => "s1", "f2" => "s2"} == r.hgetall("foo"))
    end

    def test_hmset
      r.hmset("hash", "foo1", "bar1", "foo2", "bar2")

      assert "bar1" == r.hget("hash", "foo1")
      assert "bar2" == r.hget("hash", "foo2")
    end

    def test_hmset_with_invalid_arguments
      assert_raise(Redis::CommandError) do
        r.hmset("hash", "foo1", "bar1", "foo2", "bar2", "foo3")
      end
    end

    def test_mapped_hmset
      r.mapped_hmset("foo", :f1 => "s1", :f2 => "s2")

      assert "s1" == r.hget("foo", "f1")
      assert "s2" == r.hget("foo", "f2")
    end

    def test_hmget
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")
      r.hset("foo", "f3", "s3")

      assert ["s2", "s3"] == r.hmget("foo", "f2", "f3")
    end

    def test_hmget_mapped
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")
      r.hset("foo", "f3", "s3")

      assert({"f1" => "s1"} == r.mapped_hmget("foo", "f1"))
      assert({"f1" => "s1", "f2" => "s2"} == r.mapped_hmget("foo", "f1", "f2"))
    end

    def test_hincrby
      r.hincrby("foo", "f1", 1)

      assert "1" == r.hget("foo", "f1")

      r.hincrby("foo", "f1", 2)

      assert "3" == r.hget("foo", "f1")

      r.hincrby("foo", "f1", -1)

      assert "2" == r.hget("foo", "f1")
    end

    def test_hincrbyfloat
      return if version < 205040

      r.hincrbyfloat("foo", "f1", 1.23)

      assert "1.23" == r.hget("foo", "f1")

      r.hincrbyfloat("foo", "f1", 0.77)

      assert "2" == r.hget("foo", "f1")

      r.hincrbyfloat("foo", "f1", -0.1)

      assert "1.9" == r.hget("foo", "f1")
    end
  end
end
