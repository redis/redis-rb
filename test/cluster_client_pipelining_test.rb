# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_client_pipelining_test.rb
class TestClusterClientPipelining < Test::Unit::TestCase
  include Helper::Cluster

  def test_pipelining_with_a_hash_tag
    p1 = p2 = p3 = p4 = p5 = p6 = nil

    redis.pipelined do |r|
      r.set('{Presidents.of.USA}:1', 'George Washington')
      r.set('{Presidents.of.USA}:2', 'John Adams')
      r.set('{Presidents.of.USA}:3', 'Thomas Jefferson')
      r.set('{Presidents.of.USA}:4', 'James Madison')
      r.set('{Presidents.of.USA}:5', 'James Monroe')
      r.set('{Presidents.of.USA}:6', 'John Quincy Adams')

      p1 = r.get('{Presidents.of.USA}:1')
      p2 = r.get('{Presidents.of.USA}:2')
      p3 = r.get('{Presidents.of.USA}:3')
      p4 = r.get('{Presidents.of.USA}:4')
      p5 = r.get('{Presidents.of.USA}:5')
      p6 = r.get('{Presidents.of.USA}:6')
    end

    [p1, p2, p3, p4, p5, p6].each do |actual|
      assert_true actual.is_a?(Redis::Future)
    end

    assert_equal('George Washington', p1.value)
    assert_equal('John Adams',        p2.value)
    assert_equal('Thomas Jefferson',  p3.value)
    assert_equal('James Madison',     p4.value)
    assert_equal('James Monroe',      p5.value)
    assert_equal('John Quincy Adams', p6.value)
  end

  def test_pipelining_without_hash_tags
    assert_raise(Redis::Cluster::CrossSlotPipeliningError) do
      redis.pipelined do
        redis.set(:a, 1)
        redis.set(:b, 2)
        redis.set(:c, 3)
        redis.set(:d, 4)
        redis.set(:e, 5)
        redis.set(:f, 6)

        redis.get(:a)
        redis.get(:b)
        redis.get(:c)
        redis.get(:d)
        redis.get(:e)
        redis.get(:f)
      end
    end
  end
end
