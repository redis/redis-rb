# frozen_string_literal: true

module Lint
  module Bless
    def test_bless_set_and_get
      target_version "8.12" do
        r.set("foo", "bar")

        assert_equal [], r.bless_get("foo")
        assert_equal true, r.bless_set("foo", "NO-EVICT")
        assert_equal false, r.bless_set("foo", "NO-EVICT")
        assert_equal ["NO-EVICT"], r.bless_get("foo")
      end
    end

    def test_bless_clear
      target_version "8.12" do
        r.set("foo", "bar")
        r.bless_set("foo", "NO-EVICT")

        assert_equal true, r.bless_clear("foo", "NO-EVICT")
        assert_equal false, r.bless_clear("foo", "NO-EVICT")
        assert_equal [], r.bless_get("foo")
      end
    end
  end
end
