# frozen_string_literal: true

module Lint
  module ValueTypes
    def test_exists
      assert_equal 0, r.exists("foo")

      r.set("foo", "s1")

      assert_equal 1, r.exists("foo")
    end

    def test_exists_integer
      previous_exists_returns_integer = Redis.exists_returns_integer
      Redis.exists_returns_integer = false
      assert_equal false, r.exists("foo")

      r.set("foo", "s1")

      assert_equal true, r.exists("foo")
    ensure
      Redis.exists_returns_integer = previous_exists_returns_integer
    end

    def test_variadic_exists
      assert_equal 0, r.exists("{1}foo", "{1}bar")

      r.set("{1}foo", "s1")

      assert_equal 1, r.exists("{1}foo", "{1}bar")

      r.set("{1}bar", "s2")

      assert_equal 2, r.exists("{1}foo", "{1}bar")
    end

    def test_exists?
      assert_equal false, r.exists?("{1}foo", "{1}bar")

      r.set("{1}foo", "s1")

      assert_equal true, r.exists?("{1}foo")

      r.set("{1}bar", "s1")

      assert_equal true, r.exists?("{1}foo", "{1}bar")
    end

    def test_type
      assert_equal "none", r.type("foo")

      r.set("foo", "s1")

      assert_equal "string", r.type("foo")
    end

    def test_keys
      r.set("f", "s1")
      r.set("fo", "s2")
      r.set("foo", "s3")

      assert_equal ["f", "fo", "foo"], r.keys("f*").sort
    end

    def test_expire
      r.set("foo", "s1")
      assert r.expire("foo", 2)
      assert_in_range 0..2, r.ttl("foo")

      target_version "7.0.0" do
        r.set("bar", "s2")
        refute r.expire("bar", 5, xx: true)
        assert r.expire("bar", 5, nx: true)
        refute r.expire("bar", 5, nx: true)
        assert r.expire("bar", 5, xx: true)

        r.expire("bar", 10)
        refute r.expire("bar", 15, lt: true)
        refute r.expire("bar", 5, gt: true)
        assert r.expire("bar", 15, gt: true)
        assert r.expire("bar", 5, lt: true)
      end
    end

    def test_pexpire
      target_version "2.5.4" do
        r.set("foo", "s1")
        assert r.pexpire("foo", 2000)
        assert_in_range 0..2, r.ttl("foo")
      end

      target_version "7.0.0" do
        r.set("bar", "s2")
        refute r.pexpire("bar", 5_000, xx: true)
        assert r.pexpire("bar", 5_000, nx: true)
        refute r.pexpire("bar", 5_000, nx: true)
        assert r.pexpire("bar", 5_000, xx: true)

        r.pexpire("bar", 10_000)
        refute r.pexpire("bar", 15_000, lt: true)
        refute r.pexpire("bar", 5_000, gt: true)
        assert r.pexpire("bar", 15_000, gt: true)
        assert r.pexpire("bar", 5_000, lt: true)
      end
    end

    def test_expireat
      r.set("foo", "s1")
      assert r.expireat("foo", (Time.now + 2).to_i)
      assert_in_range 0..2, r.ttl("foo")

      target_version "7.0.0" do
        r.set("bar", "s2")
        refute r.expireat("bar", (Time.now + 5).to_i, xx: true)
        assert r.expireat("bar", (Time.now + 5).to_i, nx: true)
        refute r.expireat("bar", (Time.now + 5).to_i, nx: true)
        assert r.expireat("bar", (Time.now + 5).to_i, xx: true)

        r.expireat("bar", (Time.now + 10).to_i)
        refute r.expireat("bar", (Time.now + 15).to_i, lt: true)
        refute r.expireat("bar", (Time.now + 5).to_i, gt: true)
        assert r.expireat("bar", (Time.now + 15).to_i, gt: true)
        assert r.expireat("bar", (Time.now + 5).to_i, lt: true)
      end
    end

    def test_pexpireat
      target_version "2.5.4" do
        r.set("foo", "s1")
        assert r.pexpireat("foo", (Time.now + 2).to_i * 1_000)
        assert_in_range 0..2, r.ttl("foo")
      end

      target_version "7.0.0" do
        r.set("bar", "s2")
        refute r.pexpireat("bar", (Time.now + 5).to_i * 1_000, xx: true)
        assert r.pexpireat("bar", (Time.now + 5).to_i * 1_000, nx: true)
        refute r.pexpireat("bar", (Time.now + 5).to_i * 1_000, nx: true)
        assert r.pexpireat("bar", (Time.now + 5).to_i * 1_000, xx: true)

        r.pexpireat("bar", (Time.now + 10).to_i * 1_000)
        refute r.pexpireat("bar", (Time.now + 15).to_i * 1_000, lt: true)
        refute r.pexpireat("bar", (Time.now + 5).to_i * 1_000, gt: true)
        assert r.pexpireat("bar", (Time.now + 15).to_i * 1_000, gt: true)
        assert r.pexpireat("bar", (Time.now + 5).to_i * 1_000, lt: true)
      end
    end

    def test_persist
      r.set("foo", "s1")
      r.expire("foo", 1)
      r.persist("foo")

      assert(r.ttl("foo") == -1)
    end

    def test_ttl
      r.set("foo", "s1")
      r.expire("foo", 2)
      assert_in_range 0..2, r.ttl("foo")
    end

    def test_pttl
      target_version "2.5.4" do
        r.set("foo", "s1")
        r.expire("foo", 2)
        assert_in_range 1..2000, r.pttl("foo")
      end
    end

    def test_dump_and_restore
      target_version "2.5.7" do
        r.set("foo", "a")
        v = r.dump("foo")
        r.del("foo")

        assert r.restore("foo", 1000, v)
        assert_equal "a", r.get("foo")
        assert [0, 1].include? r.ttl("foo")

        r.rpush("bar", ["b", "c", "d"])
        w = r.dump("bar")
        r.del("bar")

        assert r.restore("bar", 1000, w)
        assert_equal ["b", "c", "d"], r.lrange("bar", 0, -1)
        assert [0, 1].include? r.ttl("bar")

        r.set("bar", "somethingelse")
        assert_raises(Redis::CommandError) { r.restore("bar", 1000, w) } # ensure by default replace is false
        assert_raises(Redis::CommandError) { r.restore("bar", 1000, w, replace: false) }
        assert_equal "somethingelse", r.get("bar")
        assert r.restore("bar", 1000, w, replace: true)
        assert_equal ["b", "c", "d"], r.lrange("bar", 0, -1)
        assert [0, 1].include? r.ttl("bar")
      end
    end

    def test_move
      r.select 14
      r.flushdb

      r.set "bar", "s3"

      r.select 15

      r.set "foo", "s1"
      r.set "bar", "s2"

      assert r.move("foo", 14)
      assert_nil r.get("foo")

      assert !r.move("bar", 14)
      assert_equal "s2", r.get("bar")

      r.select 14

      assert_equal "s1", r.get("foo")
      assert_equal "s3", r.get("bar")
    end

    def test_copy
      target_version("6.2") do
        with_db(14) do
          r.flushdb

          r.set "foo", "s1"
          r.set "bar", "s2"

          assert r.copy("foo", "baz")
          assert_equal "s1", r.get("baz")

          assert !r.copy("foo", "bar")
          assert r.copy("foo", "bar", replace: true)
          assert_equal "s1", r.get("bar")
        end

        with_db(15) do
          r.set "foo", "s3"
          r.set "bar", "s4"
        end

        with_db(14) do
          assert r.copy("foo", "baz", db: 15)
          assert_equal "s1", r.get("foo")

          assert !r.copy("foo", "bar", db: 15)
          assert r.copy("foo", "bar", db: 15, replace: true)
        end

        with_db(15) do
          assert_equal "s1", r.get("baz")
          assert_equal "s1", r.get("bar")
        end
      end
    end
  end
end
