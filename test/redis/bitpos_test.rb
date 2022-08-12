# frozen_string_literal: true

require "helper"

class TestBitpos < Minitest::Test
  include Helper::Client

  def test_bitpos_empty_zero
    r.del "foo"
    assert_equal(0, r.bitpos("foo", 0))
  end

  def test_bitpos_empty_one
    r.del "foo"
    assert_equal(-1, r.bitpos("foo", 1))
  end

  def test_bitpos_zero
    r.set "foo", "\xff\xf0\x00"
    assert_equal(12, r.bitpos("foo", 0))
  end

  def test_bitpos_one
    r.set "foo", "\x00\x0f\x00"
    assert_equal(12, r.bitpos("foo", 1))
  end

  def test_bitpos_zero_end_is_given
    r.set "foo", "\xff\xff\xff"
    assert_equal(24, r.bitpos("foo", 0))
    assert_equal(24, r.bitpos("foo", 0, 0))
    assert_equal(-1, r.bitpos("foo", 0, 0, -1))
  end

  def test_bitpos_one_intervals
    r.set "foo", "\x00\xff\x00"
    assert_equal(8,  r.bitpos("foo", 1, 0, -1))
    assert_equal(8,  r.bitpos("foo", 1, 1, -1))
    assert_equal(-1, r.bitpos("foo", 1, 2, -1))
    assert_equal(-1, r.bitpos("foo", 1, 2, 200))
    assert_equal(8,  r.bitpos("foo", 1, 1, 1))
  end

  def test_bitpos_raise_exception_if_stop_not_start
    assert_raises(ArgumentError) do
      r.bitpos("foo", 0, nil, 2)
    end
  end
end
