# frozen_string_literal: true

module Lint
  module Bless
    def test_bless_set_and_get
      target_version "8.12" do
        r.set("foo", "bar")

        assert_equal [], r.bless_get("foo")
        assert_equal true, r.bless_set("foo", :no_evict)
        assert_equal false, r.bless_set("foo", :no_evict)
        assert_equal ["NO-EVICT"], r.bless_get("foo")
      end
    end

    def test_bless_clear
      target_version "8.12" do
        r.set("foo", "bar")
        r.bless_set("foo", :no_evict)

        assert_equal true, r.bless_clear("foo", :no_evict)
        assert_equal false, r.bless_clear("foo", :no_evict)
        assert_equal [], r.bless_get("foo")
      end
    end

    def test_bless_flag_spellings
      target_version "8.12" do
        r.set("foo", "bar")

        assert_equal true, r.bless_set("foo", "no-evict")
        assert_equal false, r.bless_set("foo", "NO-EVICT")
        assert_equal false, r.bless_set("foo", :"no-evict")
        assert_equal false, r.bless_set("foo", :no_evict)
        assert_equal true, r.bless_clear("foo", "No_Evict")
      end
    end

    def test_bless_set_rejects_unknown_flag
      error = assert_raises(ArgumentError) { r.bless_set("foo", :no_expire) }
      assert_match(/NO-EVICT/, error.message)
      assert_match(/no_expire/, error.message)
    end

    def test_bless_clear_rejects_unknown_flag
      assert_raises(ArgumentError) { r.bless_clear("foo", "bogus") }
    end

    def test_bless_scan_each_rejects_unknown_flag
      assert_raises(ArgumentError) { r.bless_scan_each(:bogus).to_a }
    end
  end
end
