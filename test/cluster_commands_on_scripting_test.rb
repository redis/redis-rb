# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_scripting_test.rb
# @see https://redis.io/commands#scripting
class TestClusterCommandsOnScripting < Test::Unit::TestCase
  include Helper::Cluster

  def test_eval
    script = 'return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}'
    argv = %w[first second]

    keys = %w[key1 key2]
    assert_raise(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
      redis.eval(script, keys: keys, argv: argv)
    end

    keys = %w[{key}1 {key}2]
    expected = %w[{key}1 {key}2 first second]
    assert_equal expected, redis.eval(script, keys: keys, argv: argv)
  end

  def test_evalsha
    sha = redis.script(:load, 'return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}')
    expected = %w[{key}1 {key}2 first second]
    assert_equal expected, redis.evalsha(sha, keys: %w[{key}1 {key}2], argv: %w[first second])
  end

  def test_script_debug
    target_version('3.2.0') do
      assert_equal 'OK', redis.script(:debug, 'yes')
      assert_equal 'OK', redis.script(:debug, 'no')
    end
  end

  def test_script_exists
    sha = redis.script(:load, 'return 1')
    assert_equal true, redis.script(:exists, sha)
    assert_equal false, redis.script(:exists, 'unknownsha')
  end

  def test_script_flush
    assert_equal 'OK', redis.script(:flush)
  end

  def test_script_kill
    redis_cluster_mock(kill: -> { '+OK' }) do |redis|
      assert_equal 'OK', redis.script(:kill)
    end
  end

  def test_script_load
    assert_equal 'e0e1f9fabfc9d4800c877a703b823ac0578ff8db', redis.script(:load, 'return 1')
  end
end
