require_relative "helper"

class TestDistributedConnectionHandling < Minitest::Test

  include Helper::Distributed

  def test_ping
    assert_equal ["PONG"], r.ping
  end

  def test_select
    r.set "foo", "bar"

    r.select 14
    assert_nil r.get("foo")

    r.select 15

    assert_equal "bar", r.get("foo")
  end
end
