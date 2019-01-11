require_relative "helper"

class TestDistributedConnectionHandling < Test::Unit::TestCase
  include Helper::Distributed

  def test_ping
    assert_equal %w[PONG PONG], r.ping
  end

  def test_select
    assert_raise(Redis::Distributed::CannotDistribute) { r.select 14 }
  end
end
