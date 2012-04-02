require File.expand_path("../redis_mock", File.dirname(__FILE__))

include RedisMock::Helper

test "EXISTS" do |r|
  assert false == r.exists("foo")

  r.set("foo", "s1")

  assert true ==  r.exists("foo")
end

test "TYPE" do |r|
  assert "none" == r.type("foo")

  r.set("foo", "s1")

  assert "string" == r.type("foo")
end

test "KEYS" do |r|
  r.set("f", "s1")
  r.set("fo", "s2")
  r.set("foo", "s3")

  assert ["f","fo", "foo"] == r.keys("f*").sort
end

test "EXPIRE" do |r|
  redis_mock(:expire => lambda { |*args| args == ["foo", "1"] ? ":1" : ":0" }) do
    r = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

    assert r.expire("foo", 1)
  end
end

test "PEXPIRE" do |r|
  next if version(r) < 205040

  r.set('foo', 'bar')
  assert r.pexpire('foo', 1000)
  sleep 1

  assert ! r.exists('foo')
end

test "EXPIREAT" do |r|
  redis_mock(:expireat => lambda { |*args| args == ["foo", "1328236326"] ? ":1" : ":0" }) do
    r = Redis.new(OPTIONS.merge(:port => MOCK_PORT))

    assert r.expireat("foo", 1328236326)
  end
end

test "PEXPIREAT" do |r|
  next if version(r) < 205040

  r.set('foo', 'bar')
  assert r.pexpireat('foo', 1328236326000)

  assert ! r.exists('foo')
end

test "PERSIST" do |r|
  r.set("foo", "s1")
  r.expire("foo", 1)
  r.persist("foo")

  assert(-1 == r.ttl("foo"))
end

test "TTL" do |r|
  r.set("foo", "s1")
  r.expire("foo", 1)

  assert 1 == r.ttl("foo")
end

test "PTTL" do |r|
  next if version(r) < 205040

  r.set("foo", "s1")
  r.expire("foo", 1)

  assert( (1..1000).include?(r.pttl("foo")) )

  sleep 1
  assert(-1 == r.pttl("foo"))
end

test "MOVE" do |r|
  r.select 14
  r.flushdb

  r.set "bar", "s3"

  r.select 15

  r.set "foo", "s1"
  r.set "bar", "s2"

  assert r.move("foo", 14)
  assert nil == r.get("foo")

  assert !r.move("bar", 14)
  assert "s2" == r.get("bar")

  r.select 14

  assert "s1" == r.get("foo")
  assert "s3" == r.get("bar")
end
