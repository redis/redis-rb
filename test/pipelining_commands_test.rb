# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "BULK commands" do |r|
  r.pipelined do
    r.lpush "foo", "s1"
    r.lpush "foo", "s2"
  end

  assert 2 == r.llen("foo")
  assert "s2" == r.lpop("foo")
  assert "s1" == r.lpop("foo")
end

test "MULTI_BULK commands" do |r|
  r.pipelined do
    r.mset("foo", "s1", "bar", "s2")
    r.mset("baz", "s3", "qux", "s4")
  end

  assert "s1" == r.get("foo")
  assert "s2" == r.get("bar")
  assert "s3" == r.get("baz")
  assert "s4" == r.get("qux")
end

test "BULK and MULTI_BULK commands mixed" do |r|
  r.pipelined do
    r.lpush "foo", "s1"
    r.lpush "foo", "s2"
    r.mset("baz", "s3", "qux", "s4")
  end

  assert 2 == r.llen("foo")
  assert "s2" == r.lpop("foo")
  assert "s1" == r.lpop("foo")
  assert "s3" == r.get("baz")
  assert "s4" == r.get("qux")
end

test "MULTI_BULK and BULK commands mixed" do |r|
  r.pipelined do
    r.mset("baz", "s3", "qux", "s4")
    r.lpush "foo", "s1"
    r.lpush "foo", "s2"
  end

  assert 2 == r.llen("foo")
  assert "s2" == r.lpop("foo")
  assert "s1" == r.lpop("foo")
  assert "s3" == r.get("baz")
  assert "s4" == r.get("qux")
end

test "Pipelined with an empty block" do |r|
  assert_nothing_raised do
    r.pipelined do
    end
  end

  assert 0 == r.dbsize
end

test "Returning the result of a pipeline" do |r|
  result = r.pipelined do
    r.set "foo", "bar"
    r.get "foo"
    r.get "bar"
  end

  assert ["OK", "bar", nil] == result
end

test "Assignment of results inside the block" do |r|
  r.pipelined do
    @first = r.sadd("foo", 1)
    @second = r.sadd("foo", 1)
  end

  assert_equal true, @first.value
  assert_equal false, @second.value
end

# Although we could support accessing the values in these futures,
# it doesn't make a lot of sense.
test "Assignment of results inside the block with errors" do |r|
  assert_raise do
    r.pipelined do
      r.doesnt_exist
      @first = r.sadd("foo", 1)
      r.doesnt_exist
      @second = r.sadd("foo", 1)
      r.doesnt_exist
    end
  end

  assert_raise(Redis::FutureNotReady) { @first.value }
  assert_raise(Redis::FutureNotReady) { @second.value }
end

test "Assignment of results inside a nested block" do |r|
  r.pipelined do
    @first = r.sadd("foo", 1)

    r.pipelined do
      @second = r.sadd("foo", 1)
    end
  end

  assert_equal true, @first.value
  assert_equal false, @second.value
end

test "Futures raise when confused with something else" do |r|
  r.pipelined do
    @result = r.sadd("foo", 1)
  end

  assert_raise(NoMethodError) { @result.to_s }
end

test "Futures raise when trying to access their values too early" do |r|
  r.pipelined do
    assert_raise(Redis::FutureNotReady) do
      r.sadd("foo", 1).value
    end
  end
end

test "Returning the result of an empty pipeline" do |r|
  result = r.pipelined do
  end

  assert [] == result
end

test "Nesting pipeline blocks" do |r|
  r.pipelined do
    r.set("foo", "s1")
    r.pipelined do
      r.set("bar", "s2")
    end
  end

  assert "s1" == r.get("foo")
  assert "s2" == r.get("bar")
end

test "INFO in a pipeline returns hash" do |r|
  result = r.pipelined do
    r.info
  end

  assert result.first.kind_of?(Hash)
end

test "CONFIG GET in a pipeline returns hash" do |r|
  result = r.pipelined do
    r.config(:get, "*")
  end

  assert result.first.kind_of?(Hash)
end

test "HGETALL in a pipeline returns hash" do |r|
  r.hmset("hash", "field", "value")
  result = r.pipelined do
    r.hgetall("hash")
  end

  assert result.first == { "field" => "value" }
end

test "KEYS in a pipeline" do |r|
  r.set("key", "value")
  result = r.pipelined do
    r.keys("*")
  end

  assert ["key"] == result.first
end

test "Pipeline yields a connection" do |r|
  r.pipelined do |p|
    p.set("foo", "bar")
  end

  assert_equal "bar", r.get("foo")
end
