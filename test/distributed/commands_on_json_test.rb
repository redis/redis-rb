# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnJSON < Minitest::Test
  include Helper::Distributed

  def setup
    super
    # Check if JSON module is available on all nodes
    begin
      r.nodes.each do |node|
        node.call('JSON.SET', '__test__', '$', '{}')
        node.call('JSON.DEL', '__test__')
      end
    rescue Redis::CommandError => e
      skip "JSON module not available: #{e.message}"
    end
  end

  def test_json_set_and_get
    assert r.json_set('test', '$', { name: "John", age: 30 })
    assert_equal({ name: "John", age: 30 }, r.json_get('test'))
  end

  def test_json_del
    r.json_set('test', '$', { a: 1, b: 2 })
    assert_equal 1, r.json_del('test', '$.a')
    assert_equal({ b: 2 }, r.json_get('test'))
  end

  def test_json_forget
    r.json_set('test_forget', '$', { a: 1, b: 2 })
    assert_equal 1, r.json_forget('test_forget', '$.a')
    assert_equal({ b: 2 }, r.json_get('test_forget'))
  end

  def test_json_type
    r.json_set('test', '$', { str: "hello", num: 42, arr: [1, 2], obj: { a: 1 } })
    assert_equal ["string"], r.json_type('test', '$.str')
    assert_equal ["number"], r.json_type('test', '$.num')
    assert_equal ["array"], r.json_type('test', '$.arr')
    assert_equal ["object"], r.json_type('test', '$.obj')
  end

  def test_json_numincrby
    r.json_set('test', '$', { num: 10 })
    assert_equal 15, r.json_numincrby('test', '$.num', 5)
    assert_equal 15, r.json_get('test', '$.num')
  end

  def test_json_nummultby
    r.json_set('test', '$', { num: 5 })
    assert_equal 15, r.json_nummultby('test', '$.num', 3)
    assert_equal 15, r.json_get('test', '$.num')
  end

  def test_json_strappend
    r.json_set('test', '$', { str: "hello" })
    assert_equal 11, r.json_strappend('test', '$.str', " world")
    assert_equal({ str: "hello world" }, r.json_get('test'))
  end

  def test_json_strlen
    r.json_set('test', '$', { str: "hello" })
    assert_equal [5], r.json_strlen('test', '$.str')
  end

  def test_json_arrappend
    r.json_set('test', '$', { arr: [1, 2] })
    assert_equal [4], r.json_arrappend('test', '$.arr', 3, 4)
    assert_equal({ arr: [1, 2, 3, 4] }, r.json_get('test'))
  end

  def test_json_arrindex
    r.json_set('test', '$', { arr: [1, 2, 3, 2, 1] })
    assert_equal [1], r.json_arrindex('test', '$.arr', 2)
  end

  def test_json_arrinsert
    r.json_set('test', '$', { arr: [1, 3] })
    assert_equal [3], r.json_arrinsert('test', '$.arr', 1, 2)
    assert_equal({ arr: [1, 2, 3] }, r.json_get('test'))
  end

  def test_json_arrlen
    r.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal [3], r.json_arrlen('test', '$.arr')
  end

  def test_json_arrpop
    r.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal 3, r.json_arrpop('test', '$.arr', -1)
    assert_equal({ arr: [1, 2] }, r.json_get('test'))
  end

  def test_json_arrtrim
    r.json_set('test', '$', { arr: [1, 2, 3, 4, 5] })
    assert_equal [3], r.json_arrtrim('test', '$.arr', 1, 3)
    assert_equal({ arr: [2, 3, 4] }, r.json_get('test'))
  end

  def test_json_objkeys
    r.json_set('test', '$', { a: 1, b: 2, c: 3 })
    keys = r.json_objkeys('test', '$').first.sort
    assert_equal ["a", "b", "c"], keys
  end

  def test_json_objlen
    r.json_set('test', '$', { a: 1, b: 2, c: 3 })
    assert_equal [3], r.json_objlen('test', '$')
  end

  def test_json_merge
    r.json_set('test', '$', { a: 1, b: 2 })
    assert_equal "OK", r.json_merge('test', '$', { b: 3, c: 4 })
    assert_equal({ a: 1, b: 3, c: 4 }, r.json_get('test'))
  end

  def test_json_toggle
    r.json_set('test', '$', { flag: true })
    assert_equal [0], r.json_toggle('test', '$.flag')
    assert_equal({ flag: false }, r.json_get('test'))
  end

  def test_json_clear
    r.json_set('test', '$', { arr: [1, 2, 3], obj: { a: 1 } })
    assert_equal 2, r.json_clear('test', '$.*')
    result = r.json_get('test')
    assert_equal [], result[:arr]
    assert_equal({}, result[:obj])
  end

  def test_json_mget_same_node
    # Using key tags to ensure both keys go to the same node
    r.json_set('{user}:1', '$', { name: "Alice", age: 25 })
    r.json_set('{user}:2', '$', { name: "Bob", age: 30 })
    result = r.json_mget(['{user}:1', '{user}:2'], '$.name')
    assert_equal ["Alice", "Bob"], result
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
