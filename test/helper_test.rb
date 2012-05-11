# encoding: UTF-8

require "helper"

class TestHelper < Test::Unit::TestCase

  include Helper

  def test_version_comparison
    v = Version.new("2.0.0")

    assert v < "3"
    assert v > "1"
    assert v > "2"

    assert v < "2.1"
    assert v < "2.0.1"
    assert v < "2.0.0.1"

    assert v == "2.0.0"
  end
end
