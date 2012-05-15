# encoding: UTF-8

require "helper"

class TestDistributedInternals < Test::Unit::TestCase

  include Helper::Distributed

  def test_provides_a_meaningful_inspect
    nodes = ["redis://localhost:#{PORT}/15", *NODES]
    redis = Redis::Distributed.new nodes

    assert_equal "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>", redis.inspect
  end
end
