# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "thread safety" do
  redis = Redis.connect(OPTIONS.merge(:thread_safe => true))

  threads = []

  (0..10).each do |index|
    threads << Thread.new do
      value = 2 * index
      redis.set "foo", value
    end
  end

  threads.each {|t| t.join }

  foo_value = redis.get "foo"

  assert_equal "20", foo_value

end
