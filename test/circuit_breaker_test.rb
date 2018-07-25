require_relative 'helper'

class TestCircuit < Test::Unit::TestCase

  include Helper::Client

  def test_call
    result = r.call('PING')
    assert_equal result, 'PONG'
  end

  def test_fail
    (0..90).each do |i|
      r.call('PING')
    end
    (0..10).each do |i|
      begin
        r.fails
      rescue RedisError
      end
    end

    exception = assert_raise('CircuitBreaker::CircuitBrokenException') {
      r.call('PING')
    }
    assert_equal exception.message, 'Circuit broken, please wait for timeout'
    sleep 2
  end

  def test_success
    (0..90).each do |i|
      r.call('PING')
    end
    (0..10).each do |i|
      begin
        r.fails
      rescue RedisError
      end
    end
    sleep 2
    assert_equal 'PONG', r.call('PING')
  end
end