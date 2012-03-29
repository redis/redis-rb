require File.expand_path("../redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

test "EVAL" do |r|
  assert "10" == r.eval("return 10", 0)
end

test "EVAL with command" do
  assert "OK" == r.eval("return redis.call('set','foo','bar')", 0)
end

test "EVAL with key" do
  assert "OK" == r.eval("return redis.call('set',KEYS[1],'bar')", 1, 'foo')
end

test "EVAL with argument" do
  assert "OK" == r.eval("return redis.call('set','foo',ARGV[1])", 0, 'bar')
end

test "EVAL with key and argument" do
  assert "OK" == r.eval("return redis.call('set',KEYS[1],ARGV[1])", 1, 'foo', 'bar')
end
