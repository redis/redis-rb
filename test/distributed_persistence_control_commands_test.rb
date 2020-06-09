# frozen_string_literal: true

require_relative "helper"

class TestDistributedPersistenceControlCommands < Minitest::Test
  include Helper::Distributed

  def test_save
    redis_mock(save: -> { "+SAVE" }) do |redis|
      assert_equal ["SAVE"], redis.save
    end
  end

  def test_bgsave
    redis_mock(bgsave: -> { "+BGSAVE" }) do |redis|
      assert_equal ["BGSAVE"], redis.bgsave
    end
  end

  def test_lastsave
    redis_mock(lastsave: -> { "+LASTSAVE" }) do |redis|
      assert_equal ["LASTSAVE"], redis.lastsave
    end
  end
end
