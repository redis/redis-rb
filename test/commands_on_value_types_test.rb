require_relative "helper"

class TestCommandsOnValueTypes < Test::Unit::TestCase

  include Helper::Client

  def test_exists
    assert_equal false, r.exists("foo")

    r.set("foo", "s1")

    assert_equal true,  r.exists("foo")
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

    assert_equal ["f","fo", "foo"], r.keys("f*").sort
  end

  def test_expire
    r.set("foo", "s1")
    assert r.expire("foo", 2)
    assert_in_range 0..2, r.ttl("foo")
  end

  def test_pexpire
    target_version "2.5.4" do
      r.set("foo", "s1")
      assert r.pexpire("foo", 2000)
      assert_in_range 0..2, r.ttl("foo")
    end
  end

  def test_expireat
    r.set("foo", "s1")
    assert r.expireat("foo", (Time.now + 2).to_i)
    assert_in_range 0..2, r.ttl("foo")
  end

  def test_pexpireat
    target_version "2.5.4" do
      r.set("foo", "s1")
      assert r.pexpireat("foo", (Time.now + 2).to_i * 1_000)
      assert_in_range 0..2, r.ttl("foo")
    end
  end

  def test_persist
    r.set("foo", "s1")
    r.expire("foo", 1)
    r.persist("foo")

    assert(-1 == r.ttl("foo"))
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
    assert_equal nil, r.get("foo")

    assert !r.move("bar", 14)
    assert_equal "s2", r.get("bar")

    r.select 14

    assert_equal "s1", r.get("foo")
    assert_equal "s3", r.get("bar")
  end

  def test_del
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 1, r.del("foo")

    assert_equal ["bar", "baz"], r.keys("*").sort

    assert_equal 2, r.del("bar", "baz")

    assert_equal [], r.keys("*").sort
  end

  def test_del_with_array_argument
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 1, r.del(["foo"])

    assert_equal ["bar", "baz"], r.keys("*").sort

    assert_equal 2, r.del(["bar", "baz"])

    assert_equal [], r.keys("*").sort
  end

  def test_randomkey
    assert r.randomkey.to_s.empty?

    r.set("foo", "s1")

    assert_equal "foo", r.randomkey

    r.set("bar", "s2")

    4.times do
      assert ["foo", "bar"].include?(r.randomkey)
    end
  end

  def test_rename
    r.set("foo", "s1")
    r.rename "foo", "bar"

    assert_equal "s1", r.get("bar")
    assert_equal nil, r.get("foo")
  end

  def test_renamenx
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal false, r.renamenx("foo", "bar")

    assert_equal "s1", r.get("foo")
    assert_equal "s2", r.get("bar")
  end

  def test_dbsize
    assert_equal 0, r.dbsize

    r.set("foo", "s1")

    assert_equal 1, r.dbsize
  end

  def test_flushdb
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal 2, r.dbsize

    r.flushdb

    assert_equal 0, r.dbsize
  end

  def test_flushall
    redis_mock(:flushall => lambda { "+FLUSHALL" }) do |redis|
      assert_equal "FLUSHALL", redis.flushall
    end
  end

  def test_migrate
    redis_mock(:migrate => lambda { |*args| args }) do |redis|
      options = { :host => "127.0.0.1", :port => 1234 }

      ex = assert_raise(RuntimeError) do
        redis.migrate("foo", options.reject { |key, _| key == :host })
      end
      assert ex.message =~ /host not specified/

      ex = assert_raise(RuntimeError) do
        redis.migrate("foo", options.reject { |key, _| key == :port })
      end
      assert ex.message =~ /port not specified/

      default_db = redis._client.db.to_i
      default_timeout = redis._client.timeout.to_i

      # Test defaults
      actual = redis.migrate("foo", options)
      expected = ["127.0.0.1", "1234", "foo", default_db.to_s, default_timeout.to_s]
      assert_equal expected, actual

      # Test db override
      actual = redis.migrate("foo", options.merge(:db => default_db + 1))
      expected = ["127.0.0.1", "1234", "foo", (default_db + 1).to_s, default_timeout.to_s]
      assert_equal expected, actual

      # Test timeout override
      actual = redis.migrate("foo", options.merge(:timeout => default_timeout + 1))
      expected = ["127.0.0.1", "1234", "foo", default_db.to_s, (default_timeout + 1).to_s]
      assert_equal expected, actual
    end
  end
end
