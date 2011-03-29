# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test "INFO" do |r|
  %w(last_save_time redis_version total_connections_received connected_clients total_commands_processed connected_slaves uptime_in_seconds used_memory uptime_in_days changes_since_last_save).each do |x|
    assert r.info.keys.include?(x)
  end
end

test "MONITOR" do |r|
  log = []

  wire = Wire.new do
    Redis.new(OPTIONS).monitor do |line|
      log << line
      break if log.size == 3
    end
  end

  Wire.pass while log.empty? # Faster than sleep

  r.set "foo", "s1"

  wire.join

  assert log[-1][%q{(db 15) "set" "foo" "s1"}]
end

test "MONITOR returns value for break" do |r|
  result = r.monitor do |line|
    break line
  end

  assert result == "OK"
end

test "ECHO" do |r|
  assert "foo bar baz\n" == r.echo("foo bar baz\n")
end

test "DEBUG" do |r|
  r.set "foo", "s1"

  assert r.debug(:object, "foo").kind_of?(String)
end

test_with_mocha "SYNC" do |r|
  r.client.connection.expects(:write).with [:sync]
  r.client.connection.expects(:read).returns "OK"
  assert "OK" == r.sync
end

