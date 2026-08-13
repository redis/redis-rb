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

    def test_hexpireat
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")

        assert_equal [1, -2], r.hexpireat("foo", Time.now.to_i + 400, "f1", "f2")
        assert_in_range(1..405, r.httl("foo", "f1")[0])
      end
    end

    def test_hexpireat_with_past_timestamp
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")

        assert_equal [2], r.hexpireat("foo", Time.now.to_i - 4, "f1")
        assert_equal [-2], r.httl("foo", "f1")
      end
    end

    def test_hexpireat_options
      target_version "7.4.0" do
        now = Time.now.to_i

        r.hset("foo", "f1", "v2")
        assert_equal [0], r.hexpireat("foo", now + 5_000, "f1", xx: true)
        assert_equal [-1], r.httl("foo", "f1")

        assert_equal [1], r.hexpireat("foo", now + 5_000, "f1", nx: true)
        assert_in_range(1..5_005, r.httl("foo", "f1")[0])
        assert_equal [0], r.hexpireat("foo", now + 5_000, "f1", nx: true)

        assert_equal [1], r.hexpireat("foo", now + 5_000, "f1", xx: true)

        assert_equal [0], r.hexpireat("foo", now + 50_000, "f1", lt: true)
        assert_equal [1], r.hexpireat("foo", now + 500, "f1", lt: true)

        assert_in_range(1..505, r.httl("foo", "f1")[0])
        assert_equal [1], r.hexpireat("foo", now + 50_000, "f1", gt: true)
        assert_in_range(500..50_005, r.httl("foo", "f1")[0])
      end
    end

    def test_hpexpireat
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")

        now_ms = (Time.now.to_f * 1000).to_i
        assert_equal [1, -2], r.hpexpireat("foo", now_ms + 400_000, "f1", "f2")
        assert_in_range(1..405_000, r.hpttl("foo", "f1")[0])
      end
    end

    def test_hpexpireat_with_past_timestamp
      target_version "7.4.0" do
        r.hset("foo", "f1", "v2")

        assert_equal [2], r.hpexpireat("foo", (Time.now.to_f * 1000).to_i - 4_000, "f1")
        assert_equal [-2], r.hpttl("foo", "f1")
      end
    end

    def test_hpexpireat_options
      target_version "7.4.0" do
        now_ms = (Time.now.to_f * 1000).to_i

        r.hset("foo", "f1", "v2")
        assert_equal [0], r.hpexpireat("foo", now_ms + 5_000_000, "f1", xx: true)
        assert_equal [-1], r.hpttl("foo", "f1")

        assert_equal [1], r.hpexpireat("foo", now_ms + 5_000_000, "f1", nx: true)
        assert_in_range(1..5_005_000, r.hpttl("foo", "f1")[0])
        assert_equal [0], r.hpexpireat("foo", now_ms + 5_000_000, "f1", nx: true)

        assert_equal [1], r.hpexpireat("foo", now_ms + 5_000_000, "f1", xx: true)

        assert_equal [0], r.hpexpireat("foo", now_ms + 50_000_000, "f1", lt: true)
        assert_equal [1], r.hpexpireat("foo", now_ms + 500_000, "f1", lt: true)

        assert_in_range(1..505_000, r.hpttl("foo", "f1")[0])
        assert_equal [1], r.hpexpireat("foo", now_ms + 50_000_000, "f1", gt: true)
        assert_in_range(500_000..50_005_000, r.hpttl("foo", "f1")[0])
      end
    end

    def test_hexpiretime
      target_version "7.4.0" do
        assert_equal [-2], r.hexpiretime("foo", "f1")

        r.hset("foo", "f1", "v2")

        assert_equal [-1], r.hexpiretime("foo", "f1")

        r.hexpireat("foo", Time.now.to_i + 400, "f1")

        # Tolerate clock movement between the write and the assertion.
        assert_in_range((Time.now.to_i + 370)..(Time.now.to_i + 400), r.hexpiretime("foo", "f1")[0])
      end
    end

    def test_hpexpiretime
      target_version "7.4.0" do
        assert_equal [-2], r.hpexpiretime("foo", "f1")

        r.hset("foo", "f1", "v2")

        assert_equal [-1], r.hpexpiretime("foo", "f1")

        r.hpexpireat("foo", (Time.now.to_f * 1000).to_i + 400_000, "f1")

        # Tolerate clock movement between the write and the assertion.
        now_ms = (Time.now.to_f * 1000).to_i
        assert_in_range((now_ms + 370_000)..(now_ms + 400_000), r.hpexpiretime("foo", "f1")[0])
      end
    end

    def test_hpersist
      target_version "7.4.0" do
        assert_equal [-2], r.hpersist("foo", "f1")

        r.hset("foo", "f1", "v1", "f2", "v2")

        assert_equal [-1], r.hpersist("foo", "f1")

        r.hexpire("foo", 100, "f1")

        assert_equal [1, -1, -2], r.hpersist("foo", "f1", "f2", "f3")
        assert_equal [-1], r.httl("foo", "f1")
      end
    end

    def test_hexpire_options
      target_version "7.4.0" do
        r.hset("foo", "f1", "v1")

        assert_equal [0], r.hexpire("foo", 100, "f1", xx: true)
        assert_equal [1], r.hexpire("foo", 100, "f1", nx: true)
        assert_equal [0], r.hexpire("foo", 100, "f1", nx: true)
        assert_equal [1], r.hexpire("foo", 100, "f1", xx: true)

        assert_equal [0], r.hexpire("foo", 1_000, "f1", lt: true)
        assert_equal [1], r.hexpire("foo", 50, "f1", lt: true)
        assert_equal [1], r.hexpire("foo", 1_000, "f1", gt: true)
        assert_in_range(50..1_000, r.httl("foo", "f1")[0])
      end
    end

    def test_hash_field_expiration_condition_is_exclusive
      # Client-side validation: the HEXPIRE command family accepts a single
      # condition token, so combinations fail fast without a server round trip.
      [
        -> { r.hexpire("foo", 100, "f1", nx: true, xx: true) },
        -> { r.hpexpire("foo", 100_000, "f1", gt: true, lt: true) },
        -> { r.hexpireat("foo", Time.now.to_i + 100, "f1", nx: true, gt: true) },
        -> { r.hpexpireat("foo", (Time.now.to_f * 1000).to_i + 100_000, "f1", xx: true, lt: true) }
      ].each do |call|
        assert_raises(ArgumentError) { call.call }
      end
    end

    def test_hash_field_expiration_accepts_array_form_fields
      target_version "7.4.0" do
        r.hset("foo", "f1", "v1", "f2", "v2")

        # Array-form fields (like hdel) must serialize with the right FIELDS count.
        assert_equal [1, 1], r.hexpire("foo", 100, %w[f1 f2])
        assert_equal [1, 1], r.hpexpire("foo", 100_000, %w[f1 f2])
        assert_equal [1, 1], r.hexpireat("foo", Time.now.to_i + 100, %w[f1 f2])
        assert_equal [1, 1], r.hpexpireat("foo", (Time.now.to_f * 1000).to_i + 100_000, %w[f1 f2])
        assert_equal 2, r.httl("foo", %w[f1 f2]).size
        assert_equal 2, r.hpttl("foo", %w[f1 f2]).size
        assert_equal 2, r.hexpiretime("foo", %w[f1 f2]).size
        assert_equal 2, r.hpexpiretime("foo", %w[f1 f2]).size
        assert_equal [1, 1], r.hpersist("foo", %w[f1 f2])
      end
    end

    def test_hash_field_expiration_coerces_time_values
      target_version "7.4.0" do
        r.hset("foo", "f1", "v1")

        # Integer-convertible inputs are coerced at the client boundary, like
        # expire/expireat; non-convertible inputs raise in Ruby, not on the server.
        assert_equal [1], r.hexpire("foo", "100", "f1")
        assert_equal [1], r.hexpireat("foo", (Time.now.to_i + 100).to_s, "f1")
        assert_equal [1], r.hexpireat("foo", Time.now + 100, "f1")
        assert_equal [1], r.hpexpireat("foo", ((Time.now.to_f * 1000).to_i + 100_000).to_s, "f1")
        assert_raises(ArgumentError) { r.hexpireat("foo", "tomorrow", "f1") }
      end
    end
  end
end
