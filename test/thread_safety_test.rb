# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "thread safety" do |r|
  r = init Redis.new(OPTIONS.merge(:thread_safe => true))
  r.client.disconnect

  r1, r2 = nil

  t1 = Thread.new do
    r1 = r.client.process([:set, "foo", 1]) do
      sleep 1
      r.client.send(:read)
    end
  end

  t2 = Thread.new do
    r2 = r.client.process([:get, "foo"]) do
      r.client.send(:read)
    end
  end

  t1.join
  t2.join

  assert "OK" == r1
  assert "1" == r2
end

