# encoding: UTF-8

require "helper"

class TestHelper < Test::Unit::TestCase

  include Helper

  def test_version_str_to_i
    assert_equal 200000, version_str_to_i('2.0.0')
    assert_equal 202020, version_str_to_i('2.2.2')
    assert_equal 202022, version_str_to_i('2.2.22')
    assert_equal 222222, version_str_to_i('22.22.22')
  end
end
