# frozen_string_literal: true

module Lint
  module Himport
    def test_himport_prepare_returns_ok
      target_version "8.9" do
        assert_equal "OK", r.himport_prepare("fs", %w[f1 f2])
      end
    end

    def test_himport_basic_ingestion
      target_version "8.9" do
        r.himport_prepare("shared", %w[name email age])

        assert_equal "OK", r.himport_set("shared:1", "shared", %w[alice alice@example.com 25])
        assert_equal "OK", r.himport_set("shared:2", "shared", %w[bob bob@example.com 30])

        assert_equal({ "name" => "alice", "email" => "alice@example.com", "age" => "25" }, r.hgetall("shared:1"))
        assert_equal "bob", r.hget("shared:2", "name")
      end
    end

    def test_himport_set_accepts_splat_and_array
      target_version "8.9" do
        r.himport_prepare("fs", "f1", "f2")

        assert_equal "OK", r.himport_set("k1", "fs", "v1", "v2")
        assert_equal "OK", r.himport_set("k2", "fs", %w[v1 v2])
        assert_equal r.hgetall("k1"), r.hgetall("k2")
      end
    end

    def test_himport_multiple_fieldsets_are_independent
      target_version "8.9" do
        r.himport_prepare("users", %w[name age])
        r.himport_prepare("events", %w[type payload ts])

        r.himport_set("u:1", "users", %w[alice 25])
        r.himport_set("e:1", "events", %w[click body 123])

        assert_equal({ "name" => "alice", "age" => "25" }, r.hgetall("u:1"))
        assert_equal({ "type" => "click", "payload" => "body", "ts" => "123" }, r.hgetall("e:1"))
      end
    end

    def test_himport_prepare_replaces_existing_fieldset
      target_version "8.9" do
        r.himport_prepare("fs", %w[f1 f2])
        assert_equal "OK", r.himport_set("k1", "fs", %w[v1 v2])

        # last PREPARE wins, silently
        r.himport_prepare("fs", %w[other])
        assert_equal "OK", r.himport_set("k2", "fs", %w[v])
        assert_equal({ "other" => "v" }, r.hgetall("k2"))

        error = assert_raises(Redis::CommandError) do
          r.himport_set("k3", "fs", %w[v1 v2])
        end
        assert_match(/value count/, error.message)
      end
    end

    def test_himport_positional_pairing
      target_version "8.9" do
        r.himport_prepare("order1", %w[a b c])
        r.himport_prepare("order2", %w[c b a])

        r.himport_set("order:key1", "order1", %w[va1 vb1 vc1])
        r.himport_set("order:key2", "order2", %w[vc2 vb2 va2])

        assert_equal "va1", r.hget("order:key1", "a")
        assert_equal "va2", r.hget("order:key2", "a")
        assert_equal "vc1", r.hget("order:key1", "c")
        assert_equal "vc2", r.hget("order:key2", "c")
      end
    end

    def test_himport_empty_strings_are_valid
      target_version "8.9" do
        r.himport_prepare("", ["", "f"])

        assert_equal "OK", r.himport_set("empty:1", "", ["", "v"])
        assert_equal({ "" => "", "f" => "v" }, r.hgetall("empty:1"))
      end
    end

    def test_himport_set_is_full_replace
      target_version "8.9" do
        r.hset("k1", "stale", "field")
        r.himport_prepare("fs", %w[f1])

        assert_equal "OK", r.himport_set("k1", "fs", %w[v])
        assert_equal({ "f1" => "v" }, r.hgetall("k1"))
      end
    end

    def test_himport_discard_semantics
      target_version "8.9" do
        r.himport_prepare("fs", %w[f1])
        r.himport_set("k1", "fs", %w[v])

        assert_equal 1, r.himport_discard("fs")
        assert_equal 0, r.himport_discard("fs")

        error = assert_raises(Redis::CommandError) do
          r.himport_set("k2", "fs", %w[v])
        end
        assert_match(/no such fieldset/, error.message)

        # keys written through the fieldset survive its discard
        assert_equal({ "f1" => "v" }, r.hgetall("k1"))
      end
    end

    def test_himport_discard_all_counts
      target_version "8.9" do
        r.himport_prepare("fs1", %w[f1])
        r.himport_prepare("fs2", %w[f1 f2])

        assert_equal 2, r.himport_discard_all
        assert_equal 0, r.himport_discard_all
      end
    end

    def test_himport_set_unknown_fieldset_error
      target_version "8.9" do
        error = assert_raises(Redis::CommandError) do
          r.himport_set("k1", "never-prepared", %w[v])
        end
        assert_match(/no such fieldset/, error.message)
      end
    end

    def test_himport_value_count_mismatch_error
      target_version "8.9" do
        r.himport_prepare("fs", %w[f1 f2])

        error = assert_raises(Redis::CommandError) do
          r.himport_set("k1", "fs", %w[only-one])
        end
        assert_match(/value count/, error.message)
      end
    end

    def test_himport_duplicate_field_error
      target_version "8.9" do
        error = assert_raises(Redis::CommandError) do
          r.himport_prepare("fs", %w[f1 f1])
        end
        assert_match(/duplicate field/, error.message)
      end
    end

    def test_himport_set_wrongtype_error
      target_version "8.9" do
        r.set("string-key", "value")
        r.himport_prepare("fs", %w[f1])

        error = assert_raises(Redis::CommandError) do
          r.himport_set("string-key", "fs", %w[v])
        end
        assert_match(/WRONGTYPE/, error.message)
        assert_equal "value", r.get("string-key")
      end
    end

    def test_himport_prepare_with_empty_fields_raises_argument_error
      assert_raises(ArgumentError) { r.himport_prepare("fs") }
      assert_raises(ArgumentError) { r.himport_prepare("fs", []) }
    end

    def test_himport_set_with_empty_values_raises_argument_error
      assert_raises(ArgumentError) { r.himport_set("k1", "fs") }
      assert_raises(ArgumentError) { r.himport_set("k1", "fs", []) }
    end
  end
end
