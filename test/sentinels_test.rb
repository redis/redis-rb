# encoding: UTF-8

require 'helper'

class TestSentinel < Test::Unit::TestCase

  include Helper::Sentinel

  def test_each_request_to_slave_should_get_different_slave
    slave1 = r.slave
    slave2 = r.slave
    assert_not_equal slave1, slave2
  end

  def test_slaves_should_rotate
    slave1 = r.slave
    r.slave
    assert_equal slave1, r.slave
  end
end
