# encoding: UTF-8

require "helper"

class TestDistributedPersistenceControlCommands < Test::Unit::TestCase

  include Helper
  include Helper::Distributed

  MOCK_NODES = ["redis://127.0.0.1:#{MOCK_PORT}/15"]

  def test_save
    redis_mock(:save => lambda { "+SAVE" }) do
      redis = Redis::Distributed.new(MOCK_NODES)

      assert ["SAVE"] == redis.save
    end
  end

  def test_bgsave
    redis_mock(:bgsave => lambda { "+BGSAVE" }) do
      redis = Redis::Distributed.new(MOCK_NODES)

      assert ["BGSAVE"] == redis.bgsave
    end
  end

  def test_lastsave
    redis_mock(:lastsave => lambda { "+LASTSAVE" }) do
      redis = Redis::Distributed.new(MOCK_NODES)

      assert ["LASTSAVE"] == redis.lastsave
    end
  end
end
