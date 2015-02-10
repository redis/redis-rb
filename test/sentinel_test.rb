# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class SentinalTest < Test::Unit::TestCase

  include Helper::Client

  def test_sentinel_connection
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    handler = lambda do |id|
      {
        :sentinel => lambda do |command, *args|
          commands[id] << [command, *args]
          ["127.0.0.1", "6381"]
        end
      }
    end

    RedisMock.start(handler.call(:s1), {}, 26381) do
      RedisMock.start(handler.call(:s2), {}, 26382) do
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], []
  end
end
