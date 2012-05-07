# encoding: UTF-8

require File.expand_path("./helper", File.dirname(__FILE__))

test "version_str_to_i" do
  assert_equal 200000, version_str_to_i('2.0.0')
  assert_equal 202020, version_str_to_i('2.2.2')
  assert_equal 202022, version_str_to_i('2.2.22')
  assert_equal 222222, version_str_to_i('22.22.22')
end
