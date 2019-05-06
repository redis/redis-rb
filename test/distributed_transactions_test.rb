require_relative "helper"

class TestDistributedTransactions < Minitest::Test

  include Helper::Distributed

  def test_multi_discard
    @foo = nil

    assert_raises Redis::Distributed::CannotDistribute do
      r.multi { @foo = 1 }
    end

    assert_nil @foo

    assert_raises Redis::Distributed::CannotDistribute do
      r.discard
    end
  end

  def test_watch_unwatch
    assert_raises Redis::Distributed::CannotDistribute do
      r.watch("foo")
    end

    assert_raises Redis::Distributed::CannotDistribute do
      r.unwatch
    end
  end
end
