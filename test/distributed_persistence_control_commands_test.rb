# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

require "redis/distributed"

include RedisMock::Helper

MOCK_NODES = ["redis://127.0.0.1:6380/15"]

test "SAVE" do
  redis_mock(:save => lambda { "+SAVE" }) do
    redis = Redis::Distributed.new(MOCK_NODES)

    assert ["SAVE"] == redis.save
  end
end

test "BGSAVE" do
  redis_mock(:bgsave => lambda { "+BGSAVE" }) do
    redis = Redis::Distributed.new(MOCK_NODES)

    assert ["BGSAVE"] == redis.bgsave
  end
end

test "LASTSAVE" do |r|
  redis_mock(:lastsave => lambda { "+LASTSAVE" }) do
    redis = Redis::Distributed.new(MOCK_NODES)

    assert ["LASTSAVE"] == redis.lastsave
  end
end
