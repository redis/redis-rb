# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))
require File.expand_path("./redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

setup do
  init Redis.new(OPTIONS)
end

test "SAVE" do
  redis_mock(:save => lambda { "+SAVE" }) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    assert "SAVE" == redis.save
  end
end

test "BGSAVE" do
  redis_mock(:bgsave => lambda { "+BGSAVE" }) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    assert "BGSAVE" == redis.bgsave
  end
end

test "LASTSAVE" do |r|
  redis_mock(:lastsave => lambda { "+LASTSAVE" }) do
    redis = Redis.new(OPTIONS.merge(:port => 6380))

    assert "LASTSAVE" == redis.lastsave
  end
end
