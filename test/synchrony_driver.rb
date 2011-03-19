# encoding: UTF-8

require 'eventmachine'
require 'em-synchrony'
require 'hiredis'

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

EM.synchrony do
  r = Redis.new
  r.flushdb

  r.rpush "foo", "s1"
  r.rpush "foo", "s2"

  assert 2 == r.llen("foo")
  assert "s2" == r.rpop("foo")

  EM.stop
end