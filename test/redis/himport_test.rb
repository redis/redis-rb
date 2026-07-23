# frozen_string_literal: true

require "helper"

class TestHimport < Minitest::Test
  include Helper::Client
  include Lint::Himport

  def test_himport_wire_shape
    calls = []
    handler = lambda do |*args|
      calls << args
      %w[DISCARD DISCARDALL].include?(args.first) ? ":1" : "+OK"
    end

    redis_mock(himport: handler) do |redis|
      assert_equal "OK", redis.himport_prepare("fs", "f1", "f2")
      assert_equal "OK", redis.himport_prepare("fs2", %w[f1 f2])
      assert_equal "OK", redis.himport_set("k", "fs", "v1", "v2")
      assert_equal 1, redis.himport_discard("fs")
      assert_equal 1, redis.himport_discard_all
    end

    assert_equal ["PREPARE", "fs", "f1", "f2"], calls[0]
    assert_equal ["PREPARE", "fs2", "f1", "f2"], calls[1]
    assert_equal ["SET", "k", "fs", "v1", "v2"], calls[2]
    assert_equal ["DISCARD", "fs"], calls[3]
    assert_equal ["DISCARDALL"], calls[4]
  end

  def test_fieldsets_are_connection_scoped
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1])

      other = _new_client
      error = assert_raises(Redis::CommandError) do
        other.himport_set("k1", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)

      assert_equal "OK", r.himport_set("k1", "fs", %w[v])
    ensure
      other&.close
    end
  end

  def test_himport_set_recovers_after_reconnect
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1 f2])
      r.himport_set("k1", "fs", %w[1 2])

      r.disconnect!

      # the reconnected session has no fieldsets; the client re-prepares from
      # its registry and retries transparently
      assert_equal "OK", r.himport_set("k2", "fs", %w[3 4])
      assert_equal({ "f1" => "3", "f2" => "4" }, r.hgetall("k2"))
    end
  end

  def test_himport_set_recovers_after_server_side_kill
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1])
      r.himport_set("k1", "fs", %w[v])

      admin = _new_client
      admin.client(:kill, "TYPE", "normal")

      assert_equal "OK", r.himport_set("k2", "fs", %w[v])
    ensure
      admin&.close
    end
  end

  def test_himport_set_does_not_recover_when_disabled
    target_version "8.9" do
      redis = _new_client(himport_auto_prepare: false)
      redis.himport_prepare("fs", %w[f1])
      redis.disconnect!

      error = assert_raises(Redis::CommandError) do
        redis.himport_set("k1", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)
    ensure
      redis&.close
    end
  end

  def test_himport_set_after_discard_does_not_auto_prepare
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1])
      r.himport_discard("fs")

      error = assert_raises(Redis::CommandError) do
        r.himport_set("k1", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)
    end
  end

  def test_recovery_uses_latest_schema
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1 f2])
      r.himport_prepare("fs", %w[f1 f2 f3])

      r.disconnect!

      assert_equal "OK", r.himport_set("k1", "fs", %w[1 2 3])
      assert_equal({ "f1" => "1", "f2" => "2", "f3" => "3" }, r.hgetall("k1"))
    end
  end

  def test_recovery_retries_exactly_once
    calls = []
    handler = lambda do |*args|
      calls << args.first
      args.first == "PREPARE" ? "+OK" : "-ERR no such fieldset"
    end

    redis_mock(himport: handler) do |redis|
      redis.himport_prepare("fs", %w[f1])
      error = assert_raises(Redis::CommandError) do
        redis.himport_set("k", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)
    end

    assert_equal %w[PREPARE SET PREPARE SET], calls
  end

  def test_dup_preserves_himport_auto_prepare_opt_out
    target_version "8.9" do
      redis = _new_client(himport_auto_prepare: false)
      copy = redis.dup

      copy.himport_prepare("fs", %w[f1])
      copy.disconnect!

      error = assert_raises(Redis::CommandError) do
        copy.himport_set("k1", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)
    ensure
      redis&.close
      copy&.close
    end
  end

  def test_himport_set_on_dup_client
    target_version "8.9" do
      r.himport_prepare("fs", %w[f1])

      copy = r.dup
      error = assert_raises(Redis::CommandError) do
        copy.himport_set("k1", "fs", %w[v])
      end
      assert_match(/no such fieldset/, error.message)
    ensure
      copy&.close
    end
  end

  def test_pipelined_prepare_and_set_single_batch
    target_version "8.9" do
      results = r.pipelined do |pipeline|
        pipeline.himport_prepare("pipe", %w[f1 f2])
        pipeline.himport_set("pipe:1", "pipe", %w[1 2])
        pipeline.himport_set("pipe:2", "pipe", %w[3 4])
      end

      assert_equal %w[OK OK OK], results
      assert_equal({ "f1" => "1", "f2" => "2" }, r.hgetall("pipe:1"))
      assert_equal({ "f1" => "3", "f2" => "4" }, r.hgetall("pipe:2"))
    end
  end

  def test_multi_prepare_and_set
    target_version "8.9" do
      results = r.multi do |tx|
        tx.himport_prepare("txfs", %w[f1])
        tx.himport_set("tx:1", "txfs", %w[v])
      end

      assert_equal %w[OK OK], results
      assert_equal({ "f1" => "v" }, r.hgetall("tx:1"))
    end
  end

  def test_pipelined_failed_prepare_fails_dependent_sets
    target_version "8.9" do
      results = r.pipelined(exception: false) do |pipeline|
        pipeline.himport_prepare("dupfs", %w[f1 f1])
        pipeline.himport_set("k1", "dupfs", %w[v v])
      end

      # in-array errors from `exception: false` are raw RedisClient errors, per
      # the gem's established behavior (cf. pipelining_commands_test.rb)
      assert_kind_of RedisClient::CommandError, results[0]
      assert_match(/duplicate field/, results[0].message)
      assert_kind_of RedisClient::CommandError, results[1]
      assert_match(/no such fieldset/, results[1].message)
    end
  end
end
