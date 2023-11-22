# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_client_pipelining_test.rb
class TestClusterClientPipelining < Minitest::Test
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
      assert_equal true, actual.is_a?(Redis::Future)
    end

    assert_equal('George Washington', p1.value)
    assert_equal('John Adams',        p2.value)
    assert_equal('Thomas Jefferson',  p3.value)
    assert_equal('James Madison',     p4.value)
    assert_equal('James Monroe',      p5.value)
    assert_equal('John Quincy Adams', p6.value)
  end

  def test_pipelining_without_hash_tags
    result = redis.pipelined do |pipeline|
      pipeline.set(:a, 1)
      pipeline.set(:b, 2)
      pipeline.set(:c, 3)
      pipeline.set(:d, 4)
      pipeline.set(:e, 5)
      pipeline.set(:f, 6)
    end
    assert_equal ["OK"] * 6, result

    result = redis.pipelined do |pipeline|
      pipeline.get(:a)
      pipeline.get(:b)
      pipeline.get(:c)
      pipeline.get(:d)
      pipeline.get(:e)
      pipeline.get(:f)
    end
    assert_equal 1.upto(6).map(&:to_s), result
  end

  def test_pipeline_unmapped_errors_are_bubbled_up
    ex = Class.new(StandardError)
    assert_raises(ex) do
      redis.pipelined do |_pipe|
        raise ex, "boom"
      end
    end
  end

  def test_pipeline_error_subclasses_are_mapped
    ex = Class.new(RedisClient::ConnectionError)
    assert_raises(Redis::ConnectionError) do
      redis.pipelined do |_pipe|
        raise ex, "tick tock"
      end
    end
  end
end
