# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnBless < Minitest::Test
  include Helper::Distributed
  include Lint::Bless

  def test_bless_scan_is_not_implemented
    assert_raises(NotImplementedError) { r.bless_scan(0, :no_evict) }
  end

  def test_bless_scan_each_returns_enumerator_without_block
    assert_kind_of Enumerator, r.bless_scan_each(:no_evict)
  end

  def test_bless_scan_each
    target_version "8.12" do
      blessed = %w[b1 b2 b3]
      (blessed + %w[plain1 plain2]).each { |key| r.set(key, "v") }
      blessed.each { |key| r.bless_set(key, :no_evict) }

      assert_equal blessed, r.bless_scan_each(:no_evict).to_a.uniq.sort

      yielded = []
      r.bless_scan_each(:no_evict, count: 2) { |key| yielded << key }
      assert_equal blessed, yielded.uniq.sort
    end
  end
end
