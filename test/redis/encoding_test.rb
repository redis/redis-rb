# frozen_string_literal: true

require "helper"

class TestEncoding < Minitest::Test
  include Helper::Client

  def test_returns_properly_encoded_strings
    r.set "foo", "שלום"

    assert_equal "Shalom שלום", "Shalom #{r.get('foo')}"

    refute_predicate "\xFF", :valid_encoding?
    r.set("bar", "\xFF")
    bytes = r.get("bar")
    assert_equal "\xFF".b, bytes
    assert_predicate bytes, :valid_encoding?
  end
end
