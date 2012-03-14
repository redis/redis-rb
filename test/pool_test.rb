require File.expand_path("./helper", File.dirname(__FILE__))
require "redis/pool"

setup do
  init Redis::Pool.new(OPTIONS.merge(:size => 10))
end

test "Connection pool" do |r|
  threads = Array.new(100) do
    Thread.new do
      10.times do
        r.get("foo")
      end
    end
  end

  threads.each { |t| t.join }

  assert_equal "10", r.info["connected_clients"]
end

test "pipelining" do |r|
  threads = Array.new(100) do
    Thread.new do
      10.times do
        r.pipelined do
          r.set("foo", "bar")

          r.pipelined do
            r.del("foo")
          end
        end
      end
    end
  end

  threads += Array.new(100) do
    Thread.new do
      10.times do
        r.multi do
          r.set("foo", "bar")
          r.del("foo")
        end
      end
    end
  end

  threads.each { |t| t.join }

  assert_equal "10", r.info["connected_clients"]
  assert_equal nil, r.get("foo")
end

test "MULTI fails when no block given" do |r|
  assert_raise(ArgumentError) do
    r.multi
  end
end
