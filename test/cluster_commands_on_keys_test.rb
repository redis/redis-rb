# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_keys_test.rb
# @see https://redis.io/commands#generic
class TestClusterCommandsOnKeys < Test::Unit::TestCase
  include Helper::Cluster

  def set_some_keys
    redis.set('key1', 'Hello')
    redis.set('key2', 'World')

    redis.set('{key}1', 'Hello')
    redis.set('{key}2', 'World')
  end

  def test_del
    set_some_keys

    assert_raise(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
      redis.del('key1', 'key2')
    end

    assert_equal 2, redis.del('{key}1', '{key}2')
  end

  def test_migrate
    redis.set('mykey', 1)

    assert_raise(Redis::CommandError, 'ERR Target instance replied with error: MOVED 14687 127.0.0.1:7002') do
      # We cannot move between cluster nodes.
      redis.migrate('mykey', host: '127.0.0.1', port: 7000)
    end

    redis_cluster_mock(migrate: ->(*_) { '-IOERR error or timeout writing to target instance' }) do |redis|
      assert_raise(Redis::CommandError, 'IOERR error or timeout writing to target instance') do
        redis.migrate('mykey', host: '127.0.0.1', port: 11211)
      end
    end

    redis_cluster_mock(migrate: ->(*_) { '+OK' }) do |redis|
      assert_equal 'OK', redis.migrate('mykey', host: '127.0.0.1', port: 6379)
    end
  end

  def test_object
    redis.lpush('mylist', 'Hello World')
    assert_equal 1, redis.object('refcount', 'mylist')
    expected_encoding = version < '3.2.0' ? 'ziplist' : 'quicklist'
    assert_equal expected_encoding, redis.object('encoding', 'mylist')
    expected_instance_type = RUBY_VERSION < '2.4.0' ? Fixnum : Integer
    assert_instance_of expected_instance_type, redis.object('idletime', 'mylist')

    redis.set('foo', 1000)
    assert_equal 'int', redis.object('encoding', 'foo')

    redis.set('bar', '1000bar')
    assert_equal 'embstr', redis.object('encoding', 'bar')
  end

  def test_randomkey
    set_some_keys
    assert_true redis.randomkey.is_a?(String)
  end

  def test_rename
    set_some_keys

    assert_raise(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
      redis.rename('key1', 'key3')
    end

    assert_equal 'OK', redis.rename('{key}1', '{key}3')
  end

  def test_renamenx
    set_some_keys

    assert_raise(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
      redis.renamenx('key1', 'key2')
    end

    assert_equal false, redis.renamenx('{key}1', '{key}2')
  end

  def test_sort
    redis.lpush('mylist', 3)
    redis.lpush('mylist', 1)
    redis.lpush('mylist', 5)
    redis.lpush('mylist', 2)
    redis.lpush('mylist', 4)
    assert_equal %w[1 2 3 4 5], redis.sort('mylist')
  end

  def test_touch
    target_version('3.2.1') do
      set_some_keys
      assert_equal 1, redis.touch('key1')
      assert_equal 1, redis.touch('key2')
      assert_equal 1, redis.touch('key1', 'key2')
      assert_equal 2, redis.touch('{key}1', '{key}2')
    end
  end

  def test_unlink
    target_version('4.0.0') do
      set_some_keys
      assert_raise(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
        redis.unlink('key1', 'key2', 'key3')
      end
      assert_equal 2, redis.unlink('{key}1', '{key}2', '{key}3')
    end
  end

  def test_wait
    set_some_keys
    assert_equal 1, redis.wait(1, 0)
  end

  def test_scan
    set_some_keys

    cursor = 0
    all_keys = []
    loop do
      cursor, keys = redis.scan(cursor, match: '{key}*')
      all_keys += keys
      break if cursor == '0'
    end

    assert_equal 2, all_keys.uniq.size
  end
end
