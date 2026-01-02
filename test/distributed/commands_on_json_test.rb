# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnJSON < Minitest::Test
  include Helper::Distributed
  include Lint::JSON

  def test_json_mget_same_node
    # Using key tags to ensure both keys go to the same node
    r.json_set('{user}:1', '$', { name: "Alice", age: 25 })
    r.json_set('{user}:2', '$', { name: "Bob", age: 30 })
    result = r.json_mget(['{user}:1', '{user}:2'], '$.name')
    assert_equal [["Alice"], ["Bob"]], result
  end

  def test_json_mget_different_nodes
    # Keys without tags will likely go to different nodes
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.json_mget(['user:1', 'user:2'], '$.name')
    end
  end

  def test_json_mset_same_node
    # Using key tags to ensure both keys go to the same node
    assert_equal "OK", r.json_mset([
                                     ['{user}:1', '$', { name: 'John' }],
                                     ['{user}:2', '$', { name: 'Jane' }]
                                   ])
    assert_equal({ name: 'John' }, r.json_get('{user}:1'))
    assert_equal({ name: 'Jane' }, r.json_get('{user}:2'))
  end

  def test_json_mset_different_nodes
    # Keys without tags will likely go to different nodes
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.json_mset([
                    ['user:1', '$', { name: 'John' }],
                    ['user:2', '$', { name: 'Jane' }]
                  ])
    end
  end
end
