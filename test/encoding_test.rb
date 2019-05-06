require_relative "helper"

class TestEncoding < Minitest::Test

  include Helper::Client

  def test_returns_properly_encoded_strings
    with_external_encoding("UTF-8") do
      r.set "foo", "שלום"

      assert_equal "Shalom שלום", "Shalom " + r.get("foo")
    end
  end
end
