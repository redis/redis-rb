require File.expand_path("./helper", File.dirname(__FILE__))

test "version_str_to_i" do
  assert_equal 202020, version_str_to_i('2.2.2')
  assert_equal 202012, version_str_to_i('2.2.12')
end
