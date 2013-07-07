# encoding: UTF-8

require 'helper'

class TestSentinel < Test::Unit::TestCase

  include Helper::Sentinel

  def test_slaves_should_rotate
    slave1 = r.slave
    r.slave
    assert_equal slave1, r.slave
  end
end
