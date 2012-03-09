# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

if driver == :synchrony

  setup do
    init Redis.new(OPTIONS)
  end

  test "synchrony fiber safety" do
    redis = Redis.connect

    # Fiber concurrency
    
    keys = (1..100).map do |i|
      key = "foo_#{i}"
      redis.set key, "bar_#{i}"
      key
    end

    fiber = Fiber.current
    countdown = 0
    result_count = 0
    keys.each do |key|
      countdown+= 1
      Fiber.new do
        val = redis.get(key)
        assert_equal val[4..-1], key[4..-1]
        countdown-= 1
        result_count+= 1
        if countdown == 0
          assert_equal result_count, keys.length
        end
      end.resume
    end

    EM::Synchrony.add_timer(2) do
      raise "Synchrony fiber concurrency timeout!"
    end

    while countdown > 0
      EM.next_tick { fiber.resume }
      Fiber.yield
    end
  end

end
