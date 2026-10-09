# frozen_string_literal: true

require "helper"

class TestRactor < Minitest::Test
  include Helper::Client

  MUTABLE_CONSTANTS = ["Redis::Client::ERROR_MAPPING"].freeze

  def setup
    skip("#{RUBY_ENGINE} doesn't have Ractors") unless defined?(Ractor)
    super
  end

  def test_constants_are_shareable
    unshareable = []
    each_constant(Redis) do |path, value|
      next if MUTABLE_CONSTANTS.include?(path)

      unshareable << "#{path} (#{value.class})" unless Ractor.shareable?(value)
    end

    assert_empty unshareable, "Non-main Ractors can't read these constants"
  end

  def test_commands_in_a_non_main_ractor
    skip("Ractor tests run with the Ruby driver") if ENV["DRIVER"] == "hiredis"
    ractor = Ractor.new(_format_options(protocol: PROTOCOL)) do |options|
      redis = Redis.new(options)
      redis.hset("hash", "field", "value")
      redis.zadd("zset", 1.5, "member")
      replies = redis.pipelined do |pipeline|
        pipeline.set("foo", "bar")
        pipeline.incrbyfloat("float", 1.5)
      end
      [redis.hgetall("hash"), redis.zrange("zset", 0, -1, with_scores: true), redis.exists?("hash"), replies]
    ensure
      redis&.close
    end

    assert_equal [{ "field" => "value" }, [["member", 1.5]], true, ["OK", 1.5]],
                 ractor.respond_to?(:value) ? ractor.value : ractor.take
  end

  private

  def each_constant(mod, &block)
    mod.constants(false).each do |name|
      value = mod.const_get(name, false)
      if value.is_a?(Module)
        each_constant(value, &block) if value.name&.start_with?("#{mod.name}::")
      else
        yield "#{mod.name}::#{name}", value
      end
    end
  end
end
