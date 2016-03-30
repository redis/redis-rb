# encoding: UTF-8
# frozen_string_literal: true

require File.expand_path("helper", File.dirname(__FILE__))
require "lint/lists"

class TestDistributedCommandsOnLists < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Lists

  def test_rpoplpush
    assert_raise Redis::Distributed::CannotDistribute do
      r.rpoplpush("foo", "bar")
    end
  end

  def test_brpoplpush
    assert_raise Redis::Distributed::CannotDistribute do
      r.brpoplpush("foo", "bar", :timeout => 1)
    end
  end
end
