# encoding: UTF-8

require "helper"

class TestDistributedInternals < Test::Unit::TestCase

  include Helper
  include Helper::Distributed

  def test_provides_a_meaningful_inspect
    nodes = ["redis://localhost:#{PORT}/15", *NODES]
    redis = Redis::Distributed.new nodes

    node_info = nodes.map do |node|
      "#{node} (Redis v#{redis.info.first["redis_version"]})"
    end

    assert "#<Redis client v#{Redis::VERSION} connected to #{node_info.join(', ')}>" == redis.inspect
  end
end
