
# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class TestCommandsOnMulti < Test::Unit::TestCase

  include Helper::Client
  # Redis multi command enqued all commands in a redis transaction
  # which means all comands send to redis are going to response with 
  # the string QUEUED
  # and execute with command exec
  # This test pretends to test general commands.Those ones where
  # response QUEUED response cause an issue because was not expect
  #

  def test_hgetall
    r.hset 'test', 'foo', 'bar'
    r.multi
    assert_equal 'QUEUED', r.hgetall('test')
    assert_equal [["foo", "bar"]], r.exec
  end

  def test_incrbyfloat
    r.multi
    assert_equal 'QUEUED', r.incrbyfloat('value', 1.24)
    assert_equal ["1.24"], r.exec
  end

  def test_zincrby
    r.multi
    assert_equal 'QUEUED', r.zincrby('zset', 32.0, 'a')
    assert_equal ["32"], r.exec
  end

  def test_zscore
    r.zadd('zset', 32.0, 'a')
    r.multi
    assert_equal 'QUEUED', r.zscore('zset','a')
    assert_equal ["32"], r.exec
  end

  def test_hincrbyfloat
    r.multi
    assert_equal 'QUEUED', r.hincrbyfloat('zset', 'a', 32.0)
    assert_equal ["32"], r.exec
  end

  def test_zrange
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.multi
    assert_equal 'QUEUED', r.zrange('foo', 0, -1)
    assert_equal [['s1','s2']], r.exec
  end

  def test_zrevrange
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.multi
    assert_equal 'QUEUED', r.zrevrange('foo', 0, -1)
    assert_equal [['s2','s1']], r.exec
  end

  def test_zrangebyscore
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.multi
    assert_equal 'QUEUED', r.zrangebyscore('foo', '2', '100')
    assert_equal [['s2']], r.exec
  end

  def test_zrevrangebyscore
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.multi
    assert_equal 'QUEUED', r.zrevrangebyscore('foo', '5', '100')
    assert_equal [[]], r.exec
  end

  def test_zscan
    r.multi
    r.zscan('zset', '0')
    assert_equal [['0',[]]], r.exec
  end

  def test_set
    r.multi
    assert_equal 'QUEUED', r.set('foo', 'bar')
    assert r.exec
  end
end
