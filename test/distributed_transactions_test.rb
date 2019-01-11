require_relative "helper"

class TestDistributedTransactions < Test::Unit::TestCase
  include Helper::Distributed

  def test_multi_discard
    assert_raise Redis::Distributed::CannotDistribute do
      r.multi { :dummy }
    end

    assert_raise Redis::Distributed::CannotDistribute do
      r.discard
    end
  end

  def test_watch_unwatch
    assert_raise Redis::Distributed::CannotDistribute do
      r.watch("foo")
    end

    assert_raise Redis::Distributed::CannotDistribute do
      r.unwatch
    end
  end
end
