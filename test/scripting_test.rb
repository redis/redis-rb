# encoding: UTF-8

require "helper"

class TestScripting < Test::Unit::TestCase

  include Helper::Client

  def to_sha(script)
    r.script(:load, script)
  end

  def test_script_exists
    return if version < "2.5.9" # 2.6-rc1

    a = to_sha("return 1")
    b = a.succ

    assert_equal true, r.script(:exists, a)
    assert_equal false, r.script(:exists, b)
    assert_equal [true], r.script(:exists, [a])
    assert_equal [false], r.script(:exists, [b])
    assert_equal [true, false], r.script(:exists, [a, b])
  end

  def test_script_flush
    return if version < "2.5.9" # 2.6-rc1

    sha = to_sha("return 1")
    assert r.script(:exists, sha)
    assert_equal "OK", r.script(:flush)
    assert !r.script(:exists, sha)
  end

  def test_script_kill
    return if version < "2.5.9" # 2.6-rc1

    redis_mock(:script => lambda { |arg| "+#{arg.upcase}" }) do |redis|
      assert_equal "KILL", redis.script(:kill)
    end
  end

  def test_eval
    return if version < "2.5.9" # 2.6-rc1

    assert_equal 0, r.eval("return #KEYS")
    assert_equal 0, r.eval("return #ARGV")
    assert_equal ["k1", "k2"], r.eval("return KEYS", ["k1", "k2"])
    assert_equal ["a1", "a2"], r.eval("return ARGV", [], ["a1", "a2"])
  end

  def test_eval_with_options_hash
    return if version < "2.5.9" # 2.6-rc1

    assert_equal 0, r.eval("return #KEYS", {})
    assert_equal 0, r.eval("return #ARGV", {})
    assert_equal ["k1", "k2"], r.eval("return KEYS", { :keys => ["k1", "k2"] })
    assert_equal ["a1", "a2"], r.eval("return ARGV", { :argv => ["a1", "a2"] })
  end

  def test_evalsha
    return if version < "2.5.9" # 2.6-rc1

    assert_equal 0, r.evalsha(to_sha("return #KEYS"))
    assert_equal 0, r.evalsha(to_sha("return #ARGV"))
    assert_equal ["k1", "k2"], r.evalsha(to_sha("return KEYS"), ["k1", "k2"])
    assert_equal ["a1", "a2"], r.evalsha(to_sha("return ARGV"), [], ["a1", "a2"])
  end

  def test_evalsha_with_options_hash
    return if version < "2.5.9" # 2.6-rc1

    assert_equal 0, r.evalsha(to_sha("return #KEYS"), {})
    assert_equal 0, r.evalsha(to_sha("return #ARGV"), {})
    assert_equal ["k1", "k2"], r.evalsha(to_sha("return KEYS"), { :keys => ["k1", "k2"] })
    assert_equal ["a1", "a2"], r.evalsha(to_sha("return ARGV"), { :argv => ["a1", "a2"] })
  end
end
