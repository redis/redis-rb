# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

INCREX = <<LUA
  if redis("exists",KEYS[1]) == 1
  then
  return redis("incr",KEYS[1])
  else
  return nil
  end
LUA


setup do
  init Redis.new(OPTIONS)
end

test "EVALSHA" do |r|
  assert nil == r.evalsha(INCREX, 1,:counter)
  r.set(:counter,10)
  assert 11 == r.evalsha(INCREX, 1,:counter)
end

test "EVALSHA should raise non related exceptions" do |r|
  assert_raise RuntimeError do
    r.evalsha(INCREX, 1)
  end  
end

