# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "MULTI/DISCARD" do |r|
  r.multi

  assert "QUEUED" == r.set("foo", "1")
  assert "QUEUED" == r.get("foo")

  r.discard

  assert nil == r.get("foo")
end

test "MULTI/EXEC with a block" do |r|
  r.multi do |multi|
    multi.set "foo", "s1"
  end

  assert "s1" == r.get("foo")
end

test "Assignment inside MULTI/EXEC block" do |r|
  r.multi do |m|
    @first = m.sadd("foo", 1)
    @second = m.sadd("foo", 1)
  end

  assert_equal true, @first.value
  assert_equal false, @second.value
end

# Although we could support accessing the values in these futures,
# it doesn't make a lot of sense.
test "Assignment inside MULTI/EXEC block with delayed command errors" do |r|
  assert_raise do
    r.multi do |m|
      @first = m.set("foo", "s1")
      @second = m.incr("foo") # not an integer
      @third = m.lpush("foo", "value") # wrong kind of value
    end
  end

  assert_equal "OK", @first.value
  assert_raise { @second.value }
  assert_raise { @third.value }
end

test "Assignment inside MULTI/EXEC block with immediate command errors" do |r|
  assert_raise do
    r.multi do |m|
      m.doesnt_exist
      @first = m.sadd("foo", 1)
      m.doesnt_exist
      @second = m.sadd("foo", 1)
      m.doesnt_exist
    end
  end

  assert_raise(Redis::FutureNotReady) { @first.value }
  assert_raise(Redis::FutureNotReady) { @second.value }
end

test "Raise immediate errors in MULTI/EXEC" do |r|
  assert_raise(RuntimeError) do
    r.multi do |multi|
      multi.set "bar", "s2"
      raise "Some error"
      multi.set "baz", "s3"
    end
  end

  assert nil == r.get("bar")
  assert nil == r.get("baz")
end

test "Transformed replies as return values for MULTI/EXEC block" do |r|
  _, info = r.multi do |m|
    r.info
  end

  assert info.kind_of?(Hash)
end

test "Transformed replies inside MULTI/EXEC block" do |r|
  r.multi do |m|
    @info = r.info
  end

  assert @info.value.kind_of?(Hash)
end

test "Raise command errors in MULTI/EXEC" do |r|
  assert_raise do
    r.multi do |m|
      m.set("foo", "s1")
      m.incr("foo") # not an integer
      m.lpush("foo", "value") # wrong kind of value
    end
  end

  assert "s1" == r.get("foo")
end

test "Raise command errors when accessing futures after MULTI/EXEC" do |r|
  begin
    r.multi do |m|
      m.set("foo", "s1")
      @counter = m.incr("foo") # not an integer
    end
  rescue Exception
    # Not gonna deal with it
  end

  # We should test for Redis::Error here, but hiredis doesn't yet do
  # custom error classes.
  assert_raise(RuntimeError) { @counter.value }
end

test "MULTI with a block yielding the client" do |r|
  r.multi do |multi|
    multi.set "foo", "s1"
  end

  assert "s1" == r.get("foo")
end

test "WATCH with an unmodified key" do |r|
  r.watch "foo"
  r.multi do |multi|
    multi.set "foo", "s1"
  end

  assert "s1" == r.get("foo")
end

test "WATCH with a modified key" do |r|
  r.watch "foo"
  r.set "foo", "s1"
  res = r.multi do |multi|
    multi.set "foo", "s2"
  end

  assert nil == res
  assert "s1" == r.get("foo")
end

test "UNWATCH with a modified key" do |r|
  r.watch "foo"
  r.set "foo", "s1"
  r.unwatch
  r.multi do |multi|
    multi.set "foo", "s2"
  end

  assert "s2" == r.get("foo")
end
