# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))
require "lint/value_types"

class TestEnormousKeys < Test::Unit::TestCase

  include Helper::Client
  include Lint::ValueTypes

  def setup
    super
    @redis = init(_new_client(max_key_size: 1024))
  end

  def test_huge_keys_are_rejected_on_writting
    key = "lol" * 4000

    methods_and_args =  { :persist => [key],
                          :expire => [key, 1],
                          :expireat => [key, 1],
                          :ttl => [key],
                          :pexpire => [key, 1],
                          :pexpireat => [key, 1],
                          :pttl => [key],
                          :dump => [key],
                          :set => [key, "lol"]}

    methods_and_args.each do |meth, args|
      assert_raises(Redis::KeyTooLongError) {  r.send(meth, *args) }
    end
  end
end

