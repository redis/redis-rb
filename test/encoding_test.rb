# encoding: UTF-8

require "helper"

class TestEncoding < Test::Unit::TestCase

  include Helper::Client

  def test_returns_properly_encoded_strings
    if defined?(Encoding)
      with_external_encoding("UTF-8") do
        r.set "foo", "שלום"

        assert_equal "Shalom שלום", "Shalom " + r.get("foo")
      end
    end
  end
end
