# frozen_string_literal: true

require "helper"

class TestCommandsOnValueTypes < Minitest::Test
  include Helper::Client
  include Lint::ValueTypes

  def test_del
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 0, r.del("")

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

    assert_equal 0, r.del([])

    assert_equal 1, r.del(["foo"])

    assert_equal ["bar", "baz"], r.keys("*").sort

    assert_equal 2, r.del(["bar", "baz"])

    assert_equal [], r.keys("*").sort
  end

  def test_unlink
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 0, r.unlink("")

    assert_equal ["bar", "baz", "foo"], r.keys("*").sort

    assert_equal 1, r.unlink("foo")

    assert_equal ["bar", "baz"], r.keys("*").sort

    assert_equal 2, r.unlink("bar", "baz")

    assert_equal [], r.keys("*").sort
  end

  def test_unlink_with_array_argument
    r.set "foo", "s1"
    r.set "bar", "s2"
    r.set "baz", "s3"
    r.set "bad", "s4"

    assert_equal ["bad", "bar", "baz", "foo"], r.keys("*").sort

    assert_equal 0, r.unlink([])

    assert_equal ["bad", "bar", "baz", "foo"], r.keys("*").sort

    assert_equal 1, r.unlink(["foo"])

    assert_equal ["bad", "bar", "baz"], r.keys("*").sort

    assert_equal 2, r.unlink(["bar", "baz"])

    assert_equal ["bad"], r.keys("*").sort

    assert_equal 1, r.unlink([["bad"]])

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
    assert_nil r.get("foo")
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
    # Test defaults
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal 2, r.dbsize

    r.flushdb

    assert_equal 0, r.dbsize

    # Test sync
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal 2, r.dbsize

    r.flushdb(async: false)

    assert_equal 0, r.dbsize

    # Test async
    r.set("foo", "s1")
    r.set("bar", "s2")

    assert_equal 2, r.dbsize

    r.flushdb(async: true)

    assert_equal 0, r.dbsize

    redis_mock(flushdb: ->(args) { "+FLUSHDB #{args.upcase}" }) do |redis|
      assert_equal "FLUSHDB ASYNC", redis.flushdb(async: true)
    end
  end

  def test_flushall
    # Test defaults
    redis_mock(flushall: -> { "+FLUSHALL" }) do |redis|
      assert_equal "FLUSHALL", redis.flushall
    end

    # Test sync
    redis_mock(flushall: -> { "+FLUSHALL" }) do |redis|
      assert_equal "FLUSHALL", redis.flushall(async: false)
    end

    # Test async
    redis_mock(flushall: ->(args) { "+FLUSHALL #{args.upcase}" }) do |redis|
      assert_equal "FLUSHALL ASYNC", redis.flushall(async: true)
    end
  end

  def test_migrate
    redis_mock(migrate: ->(*args) { args }) do |redis|
      options = { host: "127.0.0.1", port: 1234 }

      ex = assert_raises(RuntimeError) do
        redis.migrate("foo", options.reject { |key, _| key == :host })
      end
      assert ex.message =~ /host not specified/

      ex = assert_raises(RuntimeError) do
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
      actual = redis.migrate("foo", options.merge(db: default_db + 1))
      expected = ["127.0.0.1", "1234", "foo", (default_db + 1).to_s, default_timeout.to_s]
      assert_equal expected, actual

      # Test timeout override
      actual = redis.migrate("foo", options.merge(timeout: default_timeout + 1))
      expected = ["127.0.0.1", "1234", "foo", default_db.to_s, (default_timeout + 1).to_s]
      assert_equal expected, actual

      # Test copy override
      actual = redis.migrate('foo', options.merge(copy: true))
      expected = ['127.0.0.1', '1234', 'foo', default_db.to_s, default_timeout.to_s, 'COPY']
      assert_equal expected, actual

      # Test replace override
      actual = redis.migrate('foo', options.merge(replace: true))
      expected = ['127.0.0.1', '1234', 'foo', default_db.to_s, default_timeout.to_s, 'REPLACE']
      assert_equal expected, actual

      # Test multiple keys
      actual = redis.migrate(%w[foo bar baz], options)
      expected = ['127.0.0.1', '1234', '', default_db.to_s, default_timeout.to_s, 'KEYS', 'foo', 'bar', 'baz']
      assert_equal expected, actual
    end
  end
end
