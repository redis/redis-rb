# frozen_string_literal: true

require "helper"

class TestDistributedScripting < Minitest::Test
  include Helper::Distributed

  def to_sha(script)
    r.script(:load, script).first
  end

  def test_script_exists
    a = to_sha("return 1")
    b = a.succ

    assert_equal [true], r.script(:exists, a)
    assert_equal [false], r.script(:exists, b)
    assert_equal [[true]], r.script(:exists, [a])
    assert_equal [[false]], r.script(:exists, [b])
    assert_equal [[true, false]], r.script(:exists, [a, b])
  end

  def test_script_flush
    sha = to_sha("return 1")
    assert r.script(:exists, sha).first
    assert_equal ["OK"], r.script(:flush)
    assert !r.script(:exists, sha).first
  end

  def test_script_kill
    redis_mock(script: ->(arg) { "+#{arg.upcase}" }) do |redis|
      assert_equal ["KILL"], redis.script(:kill)
    end
  end

  def test_eval
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.eval("return #KEYS")
    end

    assert_raises(Redis::Distributed::CannotDistribute) do
      r.eval("return KEYS", ["k1", "k2"])
    end

    assert_equal ["k1"], r.eval("return KEYS", ["k1"])
    assert_equal ["a1", "a2"], r.eval("return ARGV", ["k1"], ["a1", "a2"])
  end

  def test_eval_with_options_hash
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.eval("return #KEYS", {})
    end

    assert_raises(Redis::Distributed::CannotDistribute) do
      r.eval("return KEYS", { keys: ["k1", "k2"] })
    end

    assert_equal ["k1"], r.eval("return KEYS", { keys: ["k1"] })
    assert_equal ["a1", "a2"], r.eval("return ARGV", { keys: ["k1"], argv: ["a1", "a2"] })
  end

  def test_evalsha
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.evalsha(to_sha("return #KEYS"))
    end

    assert_raises(Redis::Distributed::CannotDistribute) do
      r.evalsha(to_sha("return KEYS"), ["k1", "k2"])
    end

    assert_equal ["k1"], r.evalsha(to_sha("return KEYS"), ["k1"])
    assert_equal ["a1", "a2"], r.evalsha(to_sha("return ARGV"), ["k1"], ["a1", "a2"])
  end

  def test_evalsha_with_options_hash
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.evalsha(to_sha("return #KEYS"), {})
    end

    assert_raises(Redis::Distributed::CannotDistribute) do
      r.evalsha(to_sha("return KEYS"), { keys: ["k1", "k2"] })
    end

    assert_equal ["k1"], r.evalsha(to_sha("return KEYS"), { keys: ["k1"] })
    assert_equal ["a1", "a2"], r.evalsha(to_sha("return ARGV"), { keys: ["k1"], argv: ["a1", "a2"] })
  end

  FUNCTIONS_LIB = <<~LUA
    #!lua name=mylib
    local function myfunc(keys, args)
      return { keys, args }
    end
    redis.register_function('myfunc', myfunc)
  LUA

  def load_functions
    r.function(:flush)
    r.function(:load, FUNCTIONS_LIB)
  end

  def test_function
    target_version "7.0.0" do
      r.function(:flush)

      assert_equal ["mylib"], r.function(:load, FUNCTIONS_LIB)
      assert_equal ["mylib"], r.function(:load, FUNCTIONS_LIB, replace: true)

      libraries = r.function(:list).first
      assert_equal(["mylib"], libraries.map { |library| library["library_name"] })

      assert_equal ["OK"], r.function(:delete, "mylib")
      assert_equal [[]], r.function(:list)
    end
  end

  def test_function_runs_once_per_physical_server
    target_version "7.0.0" do
      # Two ring nodes on the same server (different databases): library mutations
      # must run once per physical server or the second run fails on collision.
      node_urls = ["redis://127.0.0.1:#{PORT}/14", "redis://127.0.0.1:#{PORT}/15"]
      redis = Redis::Distributed.new(node_urls, timeout: TIMEOUT, driver: ENV["DRIVER"], protocol: PROTOCOL)

      redis.function(:flush)
      assert_equal ["mylib"], redis.function(:load, FUNCTIONS_LIB)
      assert_equal ["OK"], redis.function(:delete, "mylib")
    end
  end

  def test_function_kill_when_idle
    target_version "7.0.0" do
      error = assert_raises(Redis::CommandError) { r.function(:kill) }
      assert_match(/NOTBUSY/, error.message)
    end
  end

  def test_function_kill_tolerates_idle_nodes
    idle = ->(*_) { "-NOTBUSY No scripts in execution right now." }
    busy = ->(*_) { "+OK" }

    RedisMock.start(function: idle) do |idle_port|
      RedisMock.start(function: busy) do |busy_port|
        node_urls = ["redis://127.0.0.1:#{idle_port}", "redis://127.0.0.1:#{busy_port}"]
        redis = Redis::Distributed.new(node_urls, timeout: TIMEOUT, driver: ENV["DRIVER"], protocol: PROTOCOL)

        assert_equal "OK", redis.function(:kill)
      end
    end
  end

  def test_fcall
    target_version "7.0.0" do
      load_functions

      assert_raises(Redis::Distributed::CannotDistribute) do
        r.fcall("myfunc")
      end

      assert_raises(Redis::Distributed::CannotDistribute) do
        r.fcall("myfunc", ["k1", "k2"])
      end

      assert_equal [["k1"], ["a1"]], r.fcall("myfunc", ["k1"], ["a1"])
      assert_equal [["k1"], ["a1"]], r.fcall("myfunc", { keys: ["k1"], argv: ["a1"] })
    end
  end

  def test_fcall_ro
    target_version "7.0.0" do
      load_functions

      assert_raises(Redis::Distributed::CannotDistribute) do
        r.fcall_ro("myfunc")
      end

      # myfunc is not registered with the no-writes flag.
      assert_raises(Redis::CommandError) { r.fcall_ro("myfunc", ["k1"]) }
    end
  end
end
