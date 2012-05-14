# encoding: UTF-8

require "helper"

class TestDistributedBlockingCommands < Test::Unit::TestCase

  include Helper
  include Helper::Distributed

  def test_blpop
    r.lpush("foo", "s1")
    r.lpush("foo", "s2")

    wire = Wire.new do
      redis = Redis::Distributed.new(NODES)
      Wire.sleep 0.1
      redis.lpush("foo", "s3")
    end

    assert_equal ["foo", "s2"], r.blpop("foo", :timeout => 1)
    assert_equal ["foo", "s1"], r.blpop("foo", :timeout => 1)
    assert_equal ["foo", "s3"], r.blpop("foo", :timeout => 1)

    wire.join
  end

  def test_brpop
    r.rpush("foo", "s1")
    r.rpush("foo", "s2")

    wire = Wire.new do
      redis = Redis::Distributed.new(NODES)
      Wire.sleep 0.1
      redis.rpush("foo", "s3")
    end

    assert_equal ["foo", "s2"], r.brpop("foo", :timeout => 1)
    assert_equal ["foo", "s1"], r.brpop("foo", :timeout => 1)
    assert_equal ["foo", "s3"], r.brpop("foo", :timeout => 1)

    wire.join
  end

  def test_blocking_pop_should_unset_a_configured_socket_timeout
    r = Redis::Distributed.new(NODES, :timeout => 0.5)

    assert_nothing_raised do
      r.blpop("foo", :timeout => 1)
    end # Errno::EAGAIN raised if socket times out before Redis command times out

    assert r.nodes.all? { |node| node.client.timeout == 0.5 }

    assert_nothing_raised do
      r.brpop("foo", :timeout => 1)
    end # Errno::EAGAIN raised if socket times out before Redis command times out

    assert r.nodes.all? { |node| node.client.timeout == 0.5 }
  end
end
