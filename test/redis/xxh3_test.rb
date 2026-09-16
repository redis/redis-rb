# frozen_string_literal: true

require "helper"

begin
  require "redis/xxh3"
rescue LoadError
  # The optional xxh3 extension hasn't been built in this checkout (it's off by default;
  # see ext/redis/xxh3/extconf.rb). Run `bundle config build.redis --enable-xxh3 && bundle
  # install` once to build it locally and exercise these tests.
end

class XXH3Test < Minitest::Test
  # Known-answer vectors: XXH3_64bits() of each value, formatted as 16 lowercase hex chars.
  # Verified two ways: (1) computed here via the vendored reference xxHash source, and
  # (2) cross-checked against a live Redis 8.8.0 server's own DIGEST command for the exact
  # same values (SET key <value>; DIGEST key) — both agree exactly, proving this extension
  # is byte-identical to the server's own implementation, not just "the same algorithm."
  KNOWN_ANSWERS = {
    "" => "2d06800538d394c2",
    "a" => "e6c632b61e964e1f",
    "bar" => "d463c860a032d362",
    "hello" => "9555e8555c62dcfd",
    "12345" => "f34099ede96b5581",
    "The quick brown fox jumps over the lazy dog" => "ce7d19a5418fb365"
  }.freeze

  def setup
    skip "xxh3 extension is not built (see ext/redis/xxh3/extconf.rb)" unless defined?(Redis::XXH3)
  end

  def test_known_answer_vectors
    KNOWN_ANSWERS.each do |value, expected|
      assert_equal expected, Redis::XXH3.hexdigest(value), "hexdigest(#{value.inspect})"
    end
  end

  def test_hexdigest_is_deterministic
    assert_equal Redis::XXH3.hexdigest("some value"), Redis::XXH3.hexdigest("some value")
  end

  def test_hexdigest_is_sixteen_lowercase_hex_characters
    assert_match(/\A[0-9a-f]{16}\z/, Redis::XXH3.hexdigest("anything"))
  end

  def test_hexdigest_differs_for_different_values
    refute_equal Redis::XXH3.hexdigest("foo"), Redis::XXH3.hexdigest("bar")
  end

  def test_hexdigest_coerces_non_string_values
    assert_equal Redis::XXH3.hexdigest("12345"), Redis::XXH3.hexdigest(12_345)
  end

  def test_hexdigest_handles_binary_data
    binary = (0..255).to_a.pack("C*")
    assert_match(/\A[0-9a-f]{16}\z/, Redis::XXH3.hexdigest(binary))
  end
end
