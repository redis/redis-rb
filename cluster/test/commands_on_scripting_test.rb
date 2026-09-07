# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_scripting_test.rb
# @see https://redis.io/commands#scripting
class TestClusterCommandsOnScripting < Minitest::Test
  include Helper::Cluster

  def test_eval
    script = 'return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}'
    argv = %w[first second]

    keys = %w[key1 key2]
    assert_raises(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
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
    assert_equal 'OK', redis.script(:debug, 'yes')
    assert_equal 'OK', redis.script(:debug, 'no')
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

  FUNCTIONS_LIB = <<~LUA
    #!lua name=mylib
    local function myfunc(keys, args)
      return { keys, args }
    end
    redis.register_function('myfunc', myfunc)
    redis.register_function{function_name='myfunc_ro', callback=myfunc, flags={'no-writes'}}
  LUA

  def load_functions
    redis.function(:flush)
    redis.function(:load, FUNCTIONS_LIB)
  end

  def test_function_load_list_delete
    target_version '7.0.0' do
      redis.function(:flush)

      # FUNCTION LOAD carries the all_shards/all_succeeded command tips, so the
      # cluster client fans it out to every primary and returns a single reply.
      assert_equal 'mylib', redis.function(:load, FUNCTIONS_LIB)
      assert_equal 'mylib', redis.function(:load, FUNCTIONS_LIB, replace: true)

      libraries = redis.function(:list)
      assert_equal(['mylib'], libraries.map { |library| library['library_name'] })
      assert_equal %w[myfunc myfunc_ro], libraries.first['functions'].map { |function| function['name'] }.sort

      assert_equal 'OK', redis.function(:delete, 'mylib')
      assert_equal [], redis.function(:list)
    end
  end

  def test_function_stats
    target_version '7.0.0' do
      load_functions

      stats = redis.function(:stats)
      assert_nil stats['running_script']
      assert stats['engines'].key?('LUA')
    end
  end

  def test_fcall
    target_version '7.0.0' do
      load_functions

      keys = %w[key1 key2]
      assert_raises(Redis::CommandError, "CROSSSLOT Keys in request don't hash to the same slot") do
        redis.fcall('myfunc', keys: keys, argv: %w[a1])
      end

      keys = %w[{key}1 {key}2]
      assert_equal [keys, %w[a1]], redis.fcall('myfunc', keys: keys, argv: %w[a1])
    end
  end

  def test_fcall_ro
    target_version '7.0.0' do
      load_functions

      assert_equal [%w[{key}1], %w[a1]], redis.fcall_ro('myfunc_ro', keys: %w[{key}1], argv: %w[a1])

      # myfunc is not registered with the no-writes flag.
      assert_raises(Redis::CommandError) { redis.fcall_ro('myfunc', keys: %w[{key}1]) }
    end
  end
end
