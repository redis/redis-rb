# encoding: UTF-8

require "helper"

class TestDistributedConnectionHandling < Test::Unit::TestCase

  include Helper
  include Helper::Distributed

  def test_ping
    assert ["PONG"] == r.ping
  end

  def test_select
    r.set "foo", "bar"

    r.select 14
    assert nil == r.get("foo")

    r.select 15

    assert "bar" == r.get("foo")
  end
end
