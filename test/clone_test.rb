# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "CLONE" do |r|
  
  r2 = r.clone
  
  r.select 0
  r2.select 5
  
  assert 0 == r.client.db
  assert 5 == r2.client.db
end

# Allow to clone redis configuration into another redis instance