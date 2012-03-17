# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

test "SAVE" do
  redis_mock(:save => lambda { "+SAVE" }) do
    redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

    assert "SAVE" == redis.save
  end
end

test "BGSAVE" do
  redis_mock(:bgsave => lambda { "+BGSAVE" }) do
    redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

    assert "BGSAVE" == redis.bgsave
  end
end

test "LASTSAVE" do
  redis_mock(:lastsave => lambda { "+LASTSAVE" }) do
    redis = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

    assert "LASTSAVE" == redis.lastsave
  end
end
