# frozen_string_literal: true

require "helper"
require "redis/xxh3"

class XXH3Test < Minitest::Test
  # Known-answer vectors: XXH3_64bits() of each value, formatted as 16 lowercase hex chars.
  # Cross-checked against a live Redis 8.8.0 server's own DIGEST command for the exact same
  # values (SET key <value>; DIGEST key) — both agree exactly, proving this pure-Ruby port
  # is byte-identical to the server's implementation, not just "the same algorithm."
  KNOWN_ANSWERS = {
    "" => "2d06800538d394c2",
    "a" => "e6c632b61e964e1f",
    "bar" => "d463c860a032d362",
    "hello" => "9555e8555c62dcfd",
    "12345" => "f34099ede96b5581",
    "The quick brown fox jumps over the lazy dog" => "ce7d19a5418fb365"
  }.freeze

  # Deterministic byte strings at every XXH3 size-class boundary (0-16, 17-128, 129-240,
  # >240 "long" input, including a block-length boundary at 1024) — this is exactly where a
  # transcription bug in a hand-ported implementation would silently surface, only for
  # certain input lengths. Values are `((i * 2654435761) % 256).chr` for i in 0...len.
  BOUNDARY_LENGTH_ANSWERS = {
    0 => "2d06800538d394c2",
    1 => "c44bdff4074eecdb",
    3 => "e7a0b893acc4c816",
    4 => "6dfdaf466aba9921",
    8 => "2750a284f571fd64",
    9 => "0096478f0ea7546c",
    16 => "549372e2d807a4d7",
    17 => "102159dcd91c46ed",
    32 => "90a4ff159d756f6b",
    64 => "4850eb2c223669c8",
    96 => "6007942bafb4fee2",
    128 => "7d7621117bd16302",
    129 => "b8c9e51cf6d3cc26",
    161 => "a7a0721ab34cb5dd",
    193 => "eac3ca8246bace89",
    240 => "07049e1af92dea00",
    241 => "a1c346f69bc74726",
    1024 => "254cff95981830a8",
    1025 => "e9280b8619a003c9",
    4096 => "5667cd2f59106bff"
  }.freeze

  def test_known_answer_vectors
    KNOWN_ANSWERS.each do |value, expected|
      assert_equal expected, Redis::XXH3.hexdigest(value), "hexdigest(#{value.inspect})"
    end
  end

  def test_boundary_length_vectors
    BOUNDARY_LENGTH_ANSWERS.each do |len, expected|
      value = (0...len).map { |i| ((i * 2_654_435_761) % 256).chr }.join
      assert_equal expected, Redis::XXH3.hexdigest(value), "hexdigest(length #{len})"
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
