require_relative "helper"

class TestCircuit < Test::Unit::TestCase

  include Helper::Client

  def test_call
    result = r.call("PING")
    assert_equal result, "PONG"
  end

  def test_fail
  	(0..90).each do |i|
  		r.call("PING")
  	end
  	(0..10).each do |i|
  		begin
  			r.fails
  		rescue RedisError
  		end
  	end

  	assert_raises CircuitBreaker::CircuitBrokenException do
  		r.call("PING")
  	end
  end

	def test_success
  	sleep 11
  	(0..90).each do |i|
  		r.call("PING")
  	end
  	(0..10).each do |i|
  		begin
  			r.fails
  		rescue RedisError
  		end
  	end
  	sleep 11
  	assert_equal "PONG", r.call("PING")
	end
end