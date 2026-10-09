# frozen_string_literal: true

require "helper"
require "redis/ractorize"

class TestRactorize < Minitest::Test
  include Helper::Client

  def setup
    skip("#{RUBY_ENGINE} doesn't have Ractors") unless defined?(Ractor)
    skip("Ractor tests run with the Ruby driver") if ENV["DRIVER"] == "hiredis"
    super
  end

  def test_errors_are_translated_in_a_non_main_ractor
    ractor = Ractor.new(_format_options(protocol: PROTOCOL)) do |options|
      redis = Redis.new(options)
      redis.set("foo", "bar")
      redis.incr("foo")
    rescue Redis::BaseError => error
      error.class
    ensure
      redis&.close
    end

    assert_equal Redis::CommandError, ractor.respond_to?(:value) ? ractor.value : ractor.take
  end
end
