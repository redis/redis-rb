# encoding: UTF-8

require "helper"

class TestDistributedPersistenceControlCommands < Test::Unit::TestCase

  include Helper
  include Helper::Distributed

  def test_save
    redis_distributed_mock(:save => lambda { "+SAVE" }) do |redis|
      assert_equal ["SAVE"], redis.save
    end
  end

  def test_bgsave
    redis_distributed_mock(:bgsave => lambda { "+BGSAVE" }) do |redis|
      assert_equal ["BGSAVE"], redis.bgsave
    end
  end

  def test_lastsave
    redis_distributed_mock(:lastsave => lambda { "+LASTSAVE" }) do |redis|
      assert_equal ["LASTSAVE"], redis.lastsave
    end
  end
end
