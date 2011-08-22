# encoding: UTF-8

require File.expand_path('./helper', File.dirname(__FILE__))

setup do
  init Redis.new(OPTIONS)
end

test 'redis_edge' do |r|
  def_info = r.info

  # stub stable version info
  r.class.class_eval {
    alias __old_info__ info
    define_method(:info) { def_info.merge 'redis_version' => REDIS_STABLE_VERSION }
  }
  assert_equal nil, redis_edge(r) { true } # not executed

  # stub edge version info
  r.class.class_eval {
    define_method(:info) { def_info.merge 'redis_version' => '99.99.99' }
  }
  assert_equal true, redis_edge(r) { true } # executed

  # reset defaults
  r.class.class_eval { alias info __old_info__ }
end

test 'version_str_to_i' do
  assert_equal 200000, version_str_to_i('2.0.0')
  assert_equal 202020, version_str_to_i('2.2.2')
  assert_equal 202022, version_str_to_i('2.2.22')
  assert_equal 222222, version_str_to_i('22.22.22')
end
