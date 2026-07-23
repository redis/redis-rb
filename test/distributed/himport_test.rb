# frozen_string_literal: true

require "helper"

class TestDistributedHimport < Minitest::Test
  include Helper::Distributed
  include Lint::Himport

  # Fan-out commands return one reply per ring node (the Redis::Distributed
  # convention, cf. flushdb/script); the default test ring has a single node.

  def test_himport_prepare_returns_ok
    target_version "8.9" do
      assert_equal ["OK"], r.himport_prepare("fs", %w[f1 f2])
    end
  end

  def test_himport_discard_semantics
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1])
      r.himport_set("k1", "fs", %w[v])

      assert_equal [1], r.himport_discard("fs")
      assert_equal [0], r.himport_discard("fs")

      error = assert_raises(Redis::CommandError) do
        r.himport_set("k2", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)

      assert_equal({ "f1" => "v" }, r.hgetall("k1"))
    end
  end

  def test_himport_discard_all_counts
    target_version "8.9" do
      r.himport_prepare("fs1", %w[f1])
      r.himport_prepare("fs2", %w[f1 f2])

      assert_equal [2], r.himport_discard_all
      assert_equal [0], r.himport_discard_all
    end
  end

  # A second ring node on another DB of the same server is still a distinct
  # physical connection — which is the scope fieldsets live in — so these
  # tests genuinely exercise two independent sessions.

  def test_prepare_fans_out_to_all_nodes
    target_version "8.9" do
      r.add_node("redis://127.0.0.1:#{PORT}/14")
      r.flushdb

      key_a, key_b = keys_on_distinct_nodes

      assert_equal %w[OK OK], r.himport_prepare("fs", %w[f1])
      assert_equal "OK", r.himport_set(key_a, "fs", %w[a])
      assert_equal "OK", r.himport_set(key_b, "fs", %w[b])
    end
  end

  def test_set_fails_when_prepare_missed_a_node
    target_version "8.9" do
      r.add_node("redis://127.0.0.1:#{PORT}/14")
      r.flushdb

      key_a, key_b = keys_on_distinct_nodes

      # prepare on one node's connection only
      r.nodes[0].himport_prepare("fs", %w[f1])

      assert_equal "OK", r.himport_set(key_a, "fs", %w[v])
      error = assert_raises(Redis::CommandError) do
        r.himport_set(key_b, "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)
    end
  end

  def test_discard_fans_out
    target_version "8.9" do
      r.add_node("redis://127.0.0.1:#{PORT}/14")
      r.flushdb

      r.himport_prepare("fs", %w[f1])
      assert_equal [1, 1], r.himport_discard("fs")

      r.himport_prepare("fs1", %w[f1])
      r.himport_prepare("fs2", %w[f1])
      assert_equal [2, 2], r.himport_discard_all
    end
  end

  def test_key_tags_route_himport_set
    target_version "8.9" do
      r.add_node("redis://127.0.0.1:#{PORT}/14")
      r.flushdb

      assert_equal r.node_for("{tag}k1").id, r.node_for("{tag}k2").id

      r.himport_prepare("fs", %w[f1])
      assert_equal "OK", r.himport_set("{tag}k1", "fs", %w[v1])
      assert_equal "OK", r.himport_set("{tag}k2", "fs", %w[v2])
    end
  end

  def test_himport_set_recovers_per_node
    target_version "8.9" do
      r.add_node("redis://127.0.0.1:#{PORT}/14")
      r.flushdb

      key_a, = keys_on_distinct_nodes
      r.himport_prepare("fs", %w[f1])

      r.node_for(key_a).disconnect!

      # the routed node's own registry repairs its session
      assert_equal "OK", r.himport_set(key_a, "fs", %w[v])
    end
  end

  private

  def keys_on_distinct_nodes
    key_a = (0..100).map { |i| "himport:#{i}" }.find { |k| r.node_for(k).id == r.nodes[0].id }
    key_b = (0..100).map { |i| "himport:#{i}" }.find { |k| r.node_for(k).id == r.nodes[1].id }
    refute_nil key_a
    refute_nil key_b
    [key_a, key_b]
  end
end
