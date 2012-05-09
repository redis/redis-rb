# encoding: UTF-8

require "helper"

class TestPersistenceControlCommands < Test::Unit::TestCase

  include Helper

  def test_save
    redis_mock(:save => lambda { "+SAVE" }) do
      redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

      assert_equal "SAVE", redis.save
    end
  end

  def test_bgsave
    redis_mock(:bgsave => lambda { "+BGSAVE" }) do
      redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

      assert_equal "BGSAVE", redis.bgsave
    end
  end

  def test_lastsave
    redis_mock(:lastsave => lambda { "+LASTSAVE" }) do
      redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

      assert_equal "LASTSAVE", redis.lastsave
    end
  end
end
