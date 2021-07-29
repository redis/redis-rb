# frozen_string_literal: true

require_relative "helper"

class TestStreams < Minitest::Test
  include Helper::Client

  def test_read_a_trimmed_entry
    r.xgroup(:create, 'k1', 'g1', '0', mkstream: true)
    entry_id = r.xadd('k1', { value: 'v1' })

    assert_equal r.xreadgroup('g1', 'c1', 'k1', '>'), { 'k1' => [[entry_id, { 'value' => 'v1' }]] }
    assert_equal r.xreadgroup('g1', 'c1', 'k1', '0'), { 'k1' => [[entry_id, { 'value' => 'v1' }]] }
    r.xtrim('k1', 0)

    assert_equal r.xreadgroup('g1', 'c1', 'k1', '0'), { 'k1' => [[entry_id, { 'value' => nil }]] }
  end
end
