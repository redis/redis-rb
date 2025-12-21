# frozen_string_literal: true

module Lint
  module Hashes
    def test_hset_and_hget
      assert_equal 1, r.hset("foo", "f1", "s1")

      assert_equal "s1", r.hget("foo", "f1")
    end

    def test_variadic_hset
      assert_equal 2, r.hset("foo", "f1", "s1", "f2", "s2")

      assert_equal "s1", r.hget("foo", "f1")
      assert_equal "s2", r.hget("foo", "f2")

      assert_equal 2, r.hset("bar", { "f1" => "s1", "f2" => "s2" })

      assert_equal "s1", r.hget("bar", "f1")
      assert_equal "s2", r.hget("bar", "f2")
    end

    def test_hsetnx
      r.hset("foo", "f1", "s1")
      r.hsetnx("foo", "f1", "s2")

      assert_equal "s1", r.hget("foo", "f1")

      r.del("foo")
      r.hsetnx("foo", "f1", "s2")

      assert_equal "s2", r.hget("foo", "f1")
    end

    def test_hdel
      r.hset("foo", "f1", "s1")

      assert_equal "s1", r.hget("foo", "f1")

      assert_equal 1, r.hdel("foo", "f1")

      assert_nil r.hget("foo", "f1")
    end

    def test_splat_hdel
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert_equal "s1", r.hget("foo", "f1")
      assert_equal "s2", r.hget("foo", "f2")

      assert_equal 2, r.hdel("foo", "f1", "f2")

      assert_nil r.hget("foo", "f1")
      assert_nil r.hget("foo", "f2")
    end

    def test_variadic_hdel
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert_equal "s1", r.hget("foo", "f1")
      assert_equal "s2", r.hget("foo", "f2")

      assert_equal 2, r.hdel("foo", ["f1", "f2"])

      assert_nil r.hget("foo", "f1")
      assert_nil r.hget("foo", "f2")
    end

    def test_hexists
      assert_equal false, r.hexists("foo", "f1")

      r.hset("foo", "f1", "s1")

      assert r.hexists("foo", "f1")
    end

    def test_hlen
      assert_equal 0, r.hlen("foo")

      r.hset("foo", "f1", "s1")

      assert_equal 1, r.hlen("foo")

      r.hset("foo", "f2", "s2")

      assert_equal 2, r.hlen("foo")
    end

    def test_hkeys
      assert_equal [], r.hkeys("foo")

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert_equal ["f1", "f2"], r.hkeys("foo")
    end

    def test_hrandfield
      target_version("6.2") do
        assert_nil r.hrandfield("foo")
        assert_equal [], r.hrandfield("foo", 1)

        error = assert_raises(ArgumentError) do
          r.hrandfield("foo", with_values: true)
        end
        assert_equal "count argument must be specified", error.message

        r.hset("foo", "f1", "s1")
        r.hset("foo", "f2", "s2")

        assert ["f1", "f2"].include?(r.hrandfield("foo"))
        assert_equal ["f1", "f2"], r.hrandfield("foo", 2).sort
        assert_equal 4, r.hrandfield("foo", -4).size

        r.hrandfield("foo", 2, with_values: true).each do |(field, value)|
          assert ["f1", "f2"].include?(field)
          assert ["s1", "s2"].include?(value)
        end
      end
    end

    def test_hvals
      assert_equal [], r.hvals("foo")

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert_equal ["s1", "s2"], r.hvals("foo")
    end

    def test_hgetall
      assert_equal({}, r.hgetall("foo"))

      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      assert_equal({ "f1" => "s1", "f2" => "s2" }, r.hgetall("foo"))
    end

    def test_hmset
      r.hmset("hash", "foo1", "bar1", "foo2", "bar2")

      assert_equal "bar1", r.hget("hash", "foo1")
      assert_equal "bar2", r.hget("hash", "foo2")
    end

    def test_hmset_with_invalid_arguments
      assert_raises(Redis::CommandError) do
        r.hmset("hash", "foo1", "bar1", "foo2", "bar2", "foo3")
      end
    end

    def test_mapped_hmset
      r.mapped_hmset("foo", f1: "s1", f2: "s2")

      assert_equal "s1", r.hget("foo", "f1")
      assert_equal "s2", r.hget("foo", "f2")
    end

    def test_hmget
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")
      r.hset("foo", "f3", "s3")

      assert_equal ["s2", "s3"], r.hmget("foo", "f2", "f3")
    end

    def test_hmget_mapped
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")
      r.hset("foo", "f3", "s3")

      assert_equal({ "f1" => "s1" }, r.mapped_hmget("foo", "f1"))
      assert_equal({ "f1" => "s1", "f2" => "s2" }, r.mapped_hmget("foo", "f1", "f2"))
    end

    def test_mapped_hmget_in_a_pipeline_returns_hash
      r.hset("foo", "f1", "s1")
      r.hset("foo", "f2", "s2")

      result = r.pipelined do |pipeline|
        pipeline.mapped_hmget("foo", "f1", "f2")
      end

      assert_equal({ "f1" => "s1", "f2" => "s2" }, result[0])
    end

    def test_hincrby
      r.hincrby("foo", "f1", 1)

      assert_equal "1", r.hget("foo", "f1")

      r.hincrby("foo", "f1", 2)

      assert_equal "3", r.hget("foo", "f1")

      r.hincrby("foo", "f1", -1)

      assert_equal "2", r.hget("foo", "f1")
    end

    def test_hincrbyfloat
      r.hincrbyfloat("foo", "f1", 1.23)

      assert_equal 1.23, Float(r.hget("foo", "f1"))

      r.hincrbyfloat("foo", "f1", 0.77)

      assert_equal "2", r.hget("foo", "f1")

      r.hincrbyfloat("foo", "f1", -0.1)

      assert_equal 1.9, Float(r.hget("foo", "f1"))
    end

    def test_hstrlen
      redis.hmset('foo', 'f1', 'HelloWorld', 'f2', 99, 'f3', -256)
      assert_equal 10, r.hstrlen('foo', 'f1')
      assert_equal 2, r.hstrlen('foo', 'f2')
      assert_equal 4, r.hstrlen('foo', 'f3')
    end

    def test_hscan
      redis.hmset('foo', 'f1', 'Jack', 'f2', 33)
      expected = ['0', [%w[f1 Jack], %w[f2 33]]]
      assert_equal expected, redis.hscan('foo', 0)
    end

    def test_hexpire
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")

        assert_equal [1], r.hexpire("foo", 4, "f1")
        assert_in_range(1..4, r.httl("foo", "f1")[0])
      end
    end

    def test_hexpire_options
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")
        assert_equal [0], r.hexpire("foo", 5, "f1", xx: true)
        assert_equal [-1], r.httl("foo", "f1")

        assert_equal [1], r.hexpire("foo", 5, "f1", nx: true)
        assert_in_range(1..5, r.httl("foo", "f1")[0])
        assert_equal [0], r.hexpire("foo", 5, "f1", nx: true)

        assert_equal [1], r.hexpire("foo", 5, "f1", xx: true)

        assert_equal [0], r.hexpire("foo", 10, "f1", lt: true)
        assert_equal [1], r.hexpire("foo", 10, "f1", gt: true)
        assert_in_range(1..10, r.httl("foo", "f1")[0])
      end
    end

    def test_httl
      target_version "7.4.0" do
        assert [-2], r.httl("foo", "f1")

        r.hset("foo", "f1", "v2")

        assert [-1], r.httl("foo", "f1")

        r.hexpire("foo", 4, "f1")

        assert_in_range(1..4, r.httl("foo", "f1")[0])
      end
    end

    def test_hpexpire
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")

        assert_equal [1], r.hpexpire("foo", 500, "f1")
        assert_in_range(1..500, r.hpttl("foo", "f1")[0])
      end
    end

    def test_hpexpire_options
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")
        assert_equal [0], r.hpexpire("foo", 500_000, "f1", xx: true)
        assert_equal [-1], r.hpttl("foo", "f1")

        assert_equal [1], r.hpexpire("foo", 500_000, "f1", nx: true)
        assert_in_range(1..500_000, r.hpttl("foo", "f1")[0])
        assert_equal [0], r.hpexpire("foo", 500_000, "f1", nx: true)

        assert_equal [1], r.hpexpire("foo", 500_000, "f1", xx: true)

        assert_equal [0], r.hpexpire("foo", 5_000_000, "f1", lt: true)
        assert_equal [1], r.hpexpire("foo", 50_000, "f1", lt: true)

        assert_in_range(1..50_000, r.hpttl("foo", "f1")[0])
        assert_equal [1], r.hpexpire("foo", 5_000_000, "f1", gt: true)
        assert_in_range(50_000..5_000_000, r.hpttl("foo", "f1")[0])
      end
    end

    def test_hpttl
      target_version "7.4.0" do
        assert [-2], r.hpttl("foo", "f1")

        r.hset("foo", "f1", "v2")

        assert [-1], r.hpttl("foo", "f1")

        r.hpexpire("foo", 400, "f1")

        assert_in_range(1..400, r.hpttl("foo", "f1")[0])
      end
    end
  end
end
