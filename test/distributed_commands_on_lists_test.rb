require_relative "helper"
require_relative "lint/lists"

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
