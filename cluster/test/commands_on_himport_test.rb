# frozen_string_literal: true

require "helper"

class TestClusterCommandsOnHimport < Minitest::Test
  include Helper::Cluster
  include Lint::Himport

  # PREPARE fails identically on every primary during the fan-out, so cluster
  # surfaces a per-node error collection instead of a single CommandError.
  def test_himport_duplicate_field_error
    target_version "8.9" do
      error = assert_raises(Redis::Cluster::CommandErrorCollection) do
        r.himport_prepare("fs", %w[f1 f1])
      end
      refute_empty error.errors
      error.errors.each_value do |node_error|
        assert_kind_of Redis::CommandError, node_error
        assert_match(/duplicate field/, node_error.message)
      end
    end
  end

  def test_himport_prepare_fans_out_to_all_primaries
    target_version "8.9" do
      owners = keys_on_distinct_masters(3)
      assert_equal 3, owners.size, "test cluster should have 3 masters"

      assert_equal "OK", r.himport_prepare("fs", %w[f1 f2])

      # a SET can only succeed on a master whose connection saw the PREPARE, so
      # success for keys owned by all three masters proves the 3-way fan-out
      owners.values.each_with_index do |key, i|
        assert_equal "OK", r.himport_set(key, "fs", ["v#{i}", "w#{i}"])
        assert_equal({ "f1" => "v#{i}", "f2" => "w#{i}" }, r.hgetall(key))
      end
    end
  end

  def test_himport_set_routes_by_slot_with_hash_tags
    target_version "8.9" do
      assert_equal r.cluster(:keyslot, "{tag}a"), r.cluster(:keyslot, "{tag}b")

      r.himport_prepare("fs", %w[f1])
      assert_equal "OK", r.himport_set("{tag}a", "fs", %w[1])
      assert_equal "OK", r.himport_set("{tag}b", "fs", %w[2])
      assert_equal({ "f1" => "1" }, r.hgetall("{tag}a"))
      assert_equal({ "f1" => "2" }, r.hgetall("{tag}b"))
    end
  end

  def test_himport_set_recovers_after_connection_kill
    target_version "8.9" do
      owners = keys_on_distinct_masters(3)
      victim_node, victim_key = owners.first

      r.himport_prepare("fs", %w[f1 f2])
      host, port = victim_node.split(":")

      admin = Redis.new(host: host, port: Integer(port))
      begin
        admin.client(:kill, "TYPE", "normal")
      ensure
        admin.close
      end

      # the rebuilt connection has no fieldsets; the client re-fans-out the
      # PREPARE from its registry and retries the SET once
      assert_equal "OK", r.himport_set(victim_key, "fs", %w[1 2])
      assert_equal({ "f1" => "1", "f2" => "2" }, r.hgetall(victim_key))
    end
  end

  def test_himport_only_multi_raises_consistency_error
    target_version "8.9" do
      assert_raises(Redis::Cluster::TransactionConsistencyError) do
        r.multi { |tx| tx.himport_prepare("fs", %w[f1]) }
      end
    end
  end

  # PREPARE + SET is still himport-only: the router cannot extract HIMPORT
  # SET's key (container-command spec), so neither command can pin the
  # transaction's node and EXEC fails loudly.
  def test_himport_prepare_and_set_multi_raises_consistency_error
    target_version "8.9" do
      assert_raises(Redis::Cluster::TransactionConsistencyError) do
        r.multi do |tx|
          tx.himport_prepare("fs", %w[f1])
          tx.himport_set("{tag}h", "fs", %w[v])
        end
      end
    end
  end

  # A normal keyed command pins the transaction to its slot's master; an
  # himport_set for a key in the same slot then executes on that node's
  # connection, which holds the fieldset thanks to the fan-out prepare.
  def test_himport_set_works_in_multi_pinned_by_keyed_command
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1 f2])

      results = r.multi do |tx|
        tx.set("{tag}pin", "x")
        tx.himport_set("{tag}h", "fs", %w[1 2])
      end
      assert_equal %w[OK OK], results
      assert_equal({ "f1" => "1", "f2" => "2" }, r.hgetall("{tag}h"))

      # order doesn't matter: an himport_set queued before the pinning command
      # is deferred and replayed once the node is known
      results = r.multi do |tx|
        tx.himport_set("{tag}h2", "fs", %w[3 4])
        tx.set("{tag}pin2", "y")
      end
      assert_equal %w[OK OK], results
      assert_equal({ "f1" => "3", "f2" => "4" }, r.hgetall("{tag}h2"))
    end
  end

  private

  # Pick one key owned by each of `count` distinct masters, resolved through
  # the server's own slot map (CLUSTER SLOTS + CLUSTER KEYSLOT).
  def keys_on_distinct_masters(count)
    ranges = r.cluster(:slots).map do |s|
      [(s["start_slot"]..s["end_slot"]), "#{s['master']['ip']}:#{s['master']['port']}"]
    end

    owners = {}
    (0..2000).each do |i|
      key = "himport:#{i}"
      slot = r.cluster(:keyslot, key)
      node = ranges.find { |range, _| range.cover?(slot) }&.last
      owners[node] ||= key
      break if owners.size >= count
    end
    owners
  end
end
