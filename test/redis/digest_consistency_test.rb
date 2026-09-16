# frozen_string_literal: true

require "helper"

begin
  require "redis/xxh3"
rescue LoadError
  # The optional xxh3 extension hasn't been built in this checkout (it's off by default;
  # see ext/redis/xxh3/extconf.rb). Skip rather than fail: the core redis gem must work
  # with zero knowledge of it either way.
end

class TestDigestConsistency < Minitest::Test
  include Helper::Client

  VALUES = [
    "",
    "a",
    "bar",
    "hello",
    "12345",
    "The quick brown fox jumps over the lazy dog",
    (0..255).to_a.pack("C*"),
    "x" * 10_000
  ].freeze

  def setup
    super
    skip "xxh3 extension is not built (see ext/redis/xxh3/extconf.rb)" unless defined?(Redis::XXH3)
  end

  def test_local_and_server_digests_agree
    target_version "8.4.0" do
      VALUES.each do |value|
        r.set("digest-consistency", value)
        assert_equal Redis::XXH3.hexdigest(value), r.digest("digest-consistency"),
                     "digest mismatch for #{value.inspect}"
      end
    end
  end

  # The tests above only prove the two *values* agree. These drive the actual SET/DELEX
  # CAS operations with a locally computed digest, end to end, so a mismatch anywhere in
  # the pipeline (encoding, argument formatting, case sensitivity) would show up as a
  # wrongly accepted/rejected write, not just a string comparison.

  def test_set_ifdeq_with_a_locally_computed_digest
    target_version "8.4.0" do
      r.set("foo", "bar")
      local_digest = Redis::XXH3.hexdigest("bar")

      assert r.set("foo", "baz", ifdeq: local_digest)
      assert_equal "baz", r.get("foo")
    end
  end

  def test_set_ifdeq_with_a_stale_locally_computed_digest
    target_version "8.4.0" do
      r.set("foo", "bar")
      stale_digest = Redis::XXH3.hexdigest("some other value")

      assert !r.set("foo", "baz", ifdeq: stale_digest)
      assert_equal "bar", r.get("foo")
    end
  end

  def test_set_ifdne_with_a_locally_computed_digest
    target_version "8.4.0" do
      r.set("foo", "bar")
      other_digest = Redis::XXH3.hexdigest("some other value")

      assert r.set("foo", "baz", ifdne: other_digest)
      assert_equal "baz", r.get("foo")
    end
  end

  def test_set_ifdne_with_the_current_locally_computed_digest
    target_version "8.4.0" do
      r.set("foo", "bar")
      current_digest = Redis::XXH3.hexdigest("bar")

      assert !r.set("foo", "baz", ifdne: current_digest)
      assert_equal "bar", r.get("foo")
    end
  end

  def test_delex_ifdeq_with_a_locally_computed_digest
    target_version "8.4.0" do
      r.set("foo", "bar")
      local_digest = Redis::XXH3.hexdigest("bar")

      assert_equal 1, r.delex("foo", ifdeq: local_digest)
      assert_nil r.get("foo")
    end
  end

  def test_delex_ifdeq_with_a_stale_locally_computed_digest
    target_version "8.4.0" do
      r.set("foo", "bar")
      stale_digest = Redis::XXH3.hexdigest("some other value")

      assert_equal 0, r.delex("foo", ifdeq: stale_digest)
      assert_equal "bar", r.get("foo")
    end
  end

  # End-to-end scenario matching the README's lock walkthrough, but using a digest (as
  # you would for a lock value too large to want to resend on every extend/release)
  # instead of comparing the raw value: acquire, extend only if still held (computing the
  # match-digest locally, no round trip), then release the same way, and confirm a stale
  # holder can do neither.
  def test_lock_extend_and_release_with_a_locally_computed_digest
    target_version "8.4.0" do
      owner_token = "owner:abc123"

      assert r.set("lock:resource", owner_token, nx: true, ex: 30)

      current_digest = Redis::XXH3.hexdigest(owner_token)
      assert r.set("lock:resource", owner_token, ex: 60, ifdeq: current_digest)

      stale_digest = Redis::XXH3.hexdigest("owner:someone-else")
      assert !r.set("lock:resource", "stolen", ifdeq: stale_digest)
      assert_equal 0, r.delex("lock:resource", ifdeq: stale_digest)
      assert_equal owner_token, r.get("lock:resource")

      assert_equal 1, r.delex("lock:resource", ifdeq: current_digest)
      assert_nil r.get("lock:resource")
    end
  end
end
