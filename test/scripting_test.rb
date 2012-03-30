# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "EVAL" do |r|
  assert 10 == r.eval("return 10", 0)
end

test "EVAL with command" do |r|
  assert "OK" == r.eval("return redis.call('set','foo','bar')", 0)
end

test "EVAL with key" do |r|
  assert "OK" == r.eval("return redis.call('set',KEYS[1],'bar')", 1, 'foo')
end

test "EVAL with argument" do |r|
  assert "OK" == r.eval("return redis.call('set','foo',ARGV[1])", 0, 'bar')
end

test "EVAL with key and argument" do |r|
  assert "OK" == r.eval("return redis.call('set',KEYS[1],ARGV[1])", 1, 'foo', 'bar')
end

test "SCRIPT LOAD" do |r|
  assert "c2164f952111fa72ceade53d02f21b514b899fac" == r.script_load("return 23")
end

test "SCRIPT FLUSH" do |r|
  r.script_load("return 23")

  assert 'OK' == r.script_flush
  assert ! r.script_exists("c2164f952111fa72ceade53d02f21b514b899fac")
end

test "SCRIPT KILL" do |r|
  r.eval('while true do end', 0)
  assert 'OK' == r.script_kill

  assert r.set('foo', 'bar') # the server can now accept commands again.
end

test "SCRIPT EXISTS with unexisting script" do |r|
  assert ! r.script_exists("unknown")
end

test "SCRIPT EXISTS with existing script" do |r|
  r.script_load("return 23")
  assert r.script_exists("c2164f952111fa72ceade53d02f21b514b899fac")
end
