 # encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "Override existing commands" do |r|
  r.set("counter", 1)

  assert 2 == r.incr("counter")

  r.client.command_map[:incr] = :decr

  assert 1 == r.incr("counter")
end

test "Override non-existing commands" do |r|
  r.set("key", "value")

  assert_raise RuntimeError do
    r.idontexist("key")
  end

  r.client.command_map[:idontexist] = :get

  assert "value" == r.idontexist("key")
end

