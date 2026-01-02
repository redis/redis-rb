# frozen_string_literal: true

require "helper"

# ruby -w -Itest cluster/test/commands_on_json_test.rb
# @see https://redis.io/commands#json
class TestClusterCommandsOnJSON < Minitest::Test
  include Helper::Cluster
  include Lint::JSON

  def test_json_mget
    r.json_set('user:1', '$', { name: "Alice", age: 25 })
    r.json_set('user:2', '$', { name: "Bob", age: 30 })
    result = r.json_mget(['user:1', 'user:2'], '$.name')
    assert_equal [["Alice"], ["Bob"]], result
  end

  def test_json_mset
    assert_equal "OK", r.json_mset([
                                     ['user:1', '$', { name: 'John' }],
                                     ['user:2', '$', { name: 'Jane' }]
                                   ])
    assert_equal({ name: 'John' }, r.json_get('user:1'))
    assert_equal({ name: 'Jane' }, r.json_get('user:2'))
  end
end
