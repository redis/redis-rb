test "SADD" do |r|
  assert true == r.sadd("foo", "s1")
  assert true == r.sadd("foo", "s2")
  assert false == r.sadd("foo", "s1")

  assert ["s1", "s2"] == r.smembers("foo").sort
end

test "Variadic SADD" do |r|
  next if version(r) < 203090 # 2.4-rc6

  assert 2 == r.sadd("foo", "s1", "s2")
  assert 1 == r.sadd("foo", "s1", "s2", "s3")

  assert ["s1", "s2", "s3"] == r.smembers("foo").sort
end

test "SREM" do |r|
  r.sadd("foo", "s1")
  r.sadd("foo", "s2")

  assert true == r.srem("foo", "s1")
  assert false == r.srem("foo", "s3")

  assert ["s2"] == r.smembers("foo")
end

test "Variadic SREM" do |r|
  next if version(r) < 203090 # 2.4-rc6

  r.sadd("foo", "s1")
  r.sadd("foo", "s2")
  r.sadd("foo", "s3")

  assert 1 == r.srem("foo", "s1", "aaa")
  assert 0 == r.srem("foo", "bbb", "ccc" "ddd")
  assert 1 == r.srem("foo", "eee", "s3")

  assert ["s2"] == r.smembers("foo")
end

test "SPOP" do |r|
  r.sadd "foo", "s1"
  r.sadd "foo", "s2"

  assert ["s1", "s2"].include?(r.spop("foo"))
  assert ["s1", "s2"].include?(r.spop("foo"))
  assert nil == r.spop("foo")
end

test "SCARD" do |r|
  assert 0 == r.scard("foo")

  r.sadd "foo", "s1"

  assert 1 == r.scard("foo")

  r.sadd "foo", "s2"

  assert 2 == r.scard("foo")
end

test "SISMEMBER" do |r|
  assert false == r.sismember("foo", "s1")

  r.sadd "foo", "s1"

  assert true ==  r.sismember("foo", "s1")
  assert false == r.sismember("foo", "s2")
end

test "SMEMBERS" do |r|
  assert [] == r.smembers("foo")

  r.sadd "foo", "s1"
  r.sadd "foo", "s2"

  assert ["s1", "s2"] == r.smembers("foo").sort
end

test "SRANDMEMBER" do |r|
  r.sadd "foo", "s1"
  r.sadd "foo", "s2"

  4.times do
    assert ["s1", "s2"].include?(r.srandmember("foo"))
  end

  assert 2 == r.scard("foo")
end
