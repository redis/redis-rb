# encoding: UTF-8

require "helper"

class TestEncoding < Test::Unit::TestCase

  include Helper

  if defined?(Encoding)
    def test_returns_properly_encoded_strings
      with_external_encoding("UTF-8") do
        r.set "foo", "שלום"

        assert "Shalom שלום" == "Shalom " + r.get("foo")
      end
    end
  end
end
