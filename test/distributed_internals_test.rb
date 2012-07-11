# encoding: UTF-8

require "helper"

class TestDistributedInternals < Test::Unit::TestCase

  include Helper::Distributed

  def test_provides_a_meaningful_inspect
    nodes = ["redis://localhost:#{PORT}/15", *NODES]
    redis = Redis::Distributed.new nodes

    assert_equal "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>", redis.inspect
  end

  def test_default_as_urls
    nodes = ["redis://localhost:#{PORT}/15", *NODES]
    redis = Redis::Distributed.new nodes
    assert_equal ["redis://localhost:#{PORT}/15", *NODES], redis.nodes.map { |node| node.client.id}
  end

  def test_default_as_config_hashes
    nodes = [OPTIONS.merge(:host => 'localhost'), OPTIONS.merge(:host => 'localhost', :port => PORT.next)]
    redis = Redis::Distributed.new nodes
    assert_equal ["redis://localhost:#{PORT}/15","redis://localhost:#{PORT.next}/15"], redis.nodes.map { |node| node.client.id }
  end

  def test_as_mix_and_match
    nodes = ["redis://localhost:7389/15", OPTIONS.merge(:host => 'localhost'), OPTIONS.merge(:host => 'localhost', :port => PORT.next)]
    redis = Redis::Distributed.new nodes
    assert_equal ["redis://localhost:7389/15", "redis://localhost:#{PORT}/15", "redis://localhost:#{PORT.next}/15"], redis.nodes.map { |node| node.client.id }
  end

  def test_override_id
    nodes = [OPTIONS.merge(:host => 'localhost', :id => "test"), OPTIONS.merge( :host => 'localhost', :port => PORT.next, :id => "test1")]
    redis = Redis::Distributed.new nodes
    assert_equal redis.nodes.first.client.id, "test"
    assert_equal redis.nodes.last.client.id,  "test1"
    assert_equal "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>", redis.inspect
  end
end
