# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))
require "lint/lists"

class TestDistributedCommandsOnLists < Minitest::Test

  include Helper::Distributed
  include Lint::Lists

  def test_rpoplpush
    assert_raises Redis::Distributed::CannotDistribute do
      r.rpoplpush("foo", "bar")
    end
  end

  def test_brpoplpush
    assert_raises Redis::Distributed::CannotDistribute do
      r.brpoplpush("foo", "bar", :timeout => 1)
    end
  end
end
