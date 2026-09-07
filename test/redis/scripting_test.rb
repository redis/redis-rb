# frozen_string_literal: true

require "helper"

class TestScripting < Minitest::Test
  include Helper::Client

  FUNCTIONS_LIB = <<~LUA
    #!lua name=mylib
    local function myfunc(keys, args)
      return { keys, args }
    end
    redis.register_function('myfunc', myfunc)
    redis.register_function{function_name='myfunc_ro', callback=myfunc, flags={'no-writes'}}
  LUA

  def to_sha(script)
    r.script(:load, script)
  end

  def load_functions
    r.function(:flush)
    r.function(:load, FUNCTIONS_LIB)
  end

  def test_script_exists
    a = to_sha("return 1")
    b = a.succ

    assert_equal true, r.script(:exists, a)
    assert_equal false, r.script(:exists, b)
    assert_equal [true], r.script(:exists, [a])
    assert_equal [false], r.script(:exists, [b])
    assert_equal [true, false], r.script(:exists, [a, b])
  end

  def test_script_flush
    sha = to_sha("return 1")
    assert r.script(:exists, sha)
    assert_equal "OK", r.script(:flush)
    assert !r.script(:exists, sha)
  end

  def test_script_kill
    redis_mock(script: ->(arg) { "+#{arg.upcase}" }) do |redis|
      assert_equal "KILL", redis.script(:kill)
    end
  end

  def test_eval
    assert_equal 0, r.eval("return #KEYS")
    assert_equal 0, r.eval("return #ARGV")
    assert_equal ["k1", "k2"], r.eval("return KEYS", ["k1", "k2"])
    assert_equal ["a1", "a2"], r.eval("return ARGV", [], ["a1", "a2"])
  end

  def test_eval_with_options_hash
    assert_equal 0, r.eval("return #KEYS", {})
    assert_equal 0, r.eval("return #ARGV", {})
    assert_equal ["k1", "k2"], r.eval("return KEYS", { keys: ["k1", "k2"] })
    assert_equal ["a1", "a2"], r.eval("return ARGV", { argv: ["a1", "a2"] })
  end

  def test_evalsha
    assert_equal 0, r.evalsha(to_sha("return #KEYS"))
    assert_equal 0, r.evalsha(to_sha("return #ARGV"))
    assert_equal ["k1", "k2"], r.evalsha(to_sha("return KEYS"), ["k1", "k2"])
    assert_equal ["a1", "a2"], r.evalsha(to_sha("return ARGV"), [], ["a1", "a2"])
  end

  def test_evalsha_no_script
    error = defined?(RedisClient::NoScriptError) ? Redis::NoScriptError : Redis::CommandError
    assert_raises error do
      redis.evalsha("invalid")
    end
  end

  def test_evalsha_with_options_hash
    assert_equal 0, r.evalsha(to_sha("return #KEYS"), {})
    assert_equal 0, r.evalsha(to_sha("return #ARGV"), {})
    assert_equal ["k1", "k2"], r.evalsha(to_sha("return KEYS"), { keys: ["k1", "k2"] })
    assert_equal ["a1", "a2"], r.evalsha(to_sha("return ARGV"), { argv: ["a1", "a2"] })
  end

  def test_function_load
    target_version "7.0.0" do
      r.function(:flush)

      assert_equal "mylib", r.function(:load, FUNCTIONS_LIB)
      assert_raises(Redis::CommandError) { r.function(:load, FUNCTIONS_LIB) }
      assert_equal "mylib", r.function(:load, FUNCTIONS_LIB, replace: true)
    end
  end

  def test_function_list
    target_version "7.0.0" do
      load_functions

      reply = r.function(:list)
      assert_equal 1, reply.size

      library = reply.first
      assert_equal "mylib", library["library_name"]
      assert_equal "LUA", library["engine"]
      assert_nil library["library_code"]

      functions = library["functions"].sort_by { |function| function["name"] }
      assert_equal(%w[myfunc myfunc_ro], functions.map { |function| function["name"] })
      assert_nil functions.first["description"]
      assert_equal [], functions.first["flags"]
      assert_equal ["no-writes"], functions.last["flags"]
    end
  end

  def test_function_list_with_options
    target_version "7.0.0" do
      load_functions

      assert_equal [], r.function(:list, libraryname: "nosuchlib")

      reply = r.function(:list, libraryname: "mylib", withcode: true)
      assert_equal 1, reply.size
      assert_equal FUNCTIONS_LIB, reply.first["library_code"]

      positional = r.function(:list, "LIBRARYNAME", "mylib", "WITHCODE")
      assert_equal 1, positional.size
      assert_equal FUNCTIONS_LIB, positional.first["library_code"]
    end
  end

  def test_function_delete
    target_version "7.0.0" do
      load_functions

      assert_equal "OK", r.function(:delete, "mylib")
      assert_equal [], r.function(:list)
      assert_raises(Redis::CommandError) { r.function(:delete, "mylib") }
    end
  end

  def test_function_flush
    target_version "7.0.0" do
      load_functions

      assert_equal 1, r.function(:list).size
      assert_equal "OK", r.function(:flush)
      assert_equal [], r.function(:list)

      r.function(:load, FUNCTIONS_LIB)
      assert_equal "OK", r.function(:flush, "ASYNC")
      assert_equal [], r.function(:list)
    end
  end

  def test_function_dump_and_restore
    target_version "7.0.0" do
      load_functions

      payload = r.function(:dump)
      assert_kind_of String, payload

      r.function(:flush)
      assert_equal "OK", r.function(:restore, payload)
      assert_equal(["mylib"], r.function(:list).map { |library| library["library_name"] })

      # APPEND (the default policy) aborts on collision; REPLACE and FLUSH succeed.
      assert_raises(Redis::CommandError) { r.function(:restore, payload) }
      assert_equal "OK", r.function(:restore, payload, policy: :replace)
      assert_equal "OK", r.function(:restore, payload, policy: :flush)
    end
  end

  def test_function_stats
    target_version "7.0.0" do
      load_functions

      stats = r.function(:stats)
      assert_nil stats["running_script"]
      assert stats["engines"].key?("LUA")
      assert_kind_of Integer, stats["engines"]["LUA"]["libraries_count"]
      assert_kind_of Integer, stats["engines"]["LUA"]["functions_count"]
    end
  end

  def test_function_kill
    target_version "7.0.0" do
      error = assert_raises(Redis::CommandError) { r.function(:kill) }
      assert_match(/NOTBUSY/, error.message)
    end
  end

  def test_fcall
    target_version "7.0.0" do
      load_functions

      assert_equal [[], []], r.fcall("myfunc")
      assert_equal [["k1", "k2"], []], r.fcall("myfunc", ["k1", "k2"])
      assert_equal [["k1"], ["a1", "a2"]], r.fcall("myfunc", ["k1"], ["a1", "a2"])
    end
  end

  def test_fcall_with_options_hash
    target_version "7.0.0" do
      load_functions

      assert_equal [[], []], r.fcall("myfunc", {})
      assert_equal [["k1"], ["a1"]], r.fcall("myfunc", { keys: ["k1"], argv: ["a1"] })
    end
  end

  def test_fcall_unknown_function
    target_version "7.0.0" do
      load_functions

      assert_raises(Redis::CommandError) { r.fcall("nosuchfunc") }
    end
  end

  def test_fcall_ro
    target_version "7.0.0" do
      load_functions

      assert_equal [["k1"], ["a1"]], r.fcall_ro("myfunc_ro", ["k1"], ["a1"])
      assert_equal [["k1"], ["a1"]], r.fcall_ro("myfunc_ro", { keys: ["k1"], argv: ["a1"] })

      # myfunc is not registered with the no-writes flag.
      assert_raises(Redis::CommandError) { r.fcall_ro("myfunc") }
    end
  end

  def test_fcall_in_pipeline
    target_version "7.0.0" do
      load_functions

      result = r.pipelined do |pipeline|
        pipeline.fcall("myfunc", ["k1"], ["a1"])
        pipeline.function(:list)
      end

      assert_equal [["k1"], ["a1"]], result.first
      assert_equal(["mylib"], result.last.map { |library| library["library_name"] })
    end
  end
end
