# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "SCRIPT LOAD" do |r|
  next if version(r) < 205040

  assert "c2164f952111fa72ceade53d02f21b514b899fac" == r.script_load("return 23")
end
