# frozen_string_literal: true

require "helper"

# ruby -w -Itest cluster/test/commands_on_json_test.rb
# @see https://redis.io/commands#json
class TestClusterCommandsOnJSON < Minitest::Test
  include Helper::Cluster

  def setup
    super
    # Check if JSON module is available
    begin
      redis.call('JSON.SET', '__test__', '$', '{}')
      redis.call('JSON.DEL', '__test__')
    rescue Redis::CommandError => e
      skip "JSON module not available: #{e.message}"
    end
  end

  def test_json_set_and_get
    assert redis.json_set('test', '$', { name: "John", age: 30 })
    assert_equal({ name: "John", age: 30 }, redis.json_get('test'))
  end

  def test_json_mget
    redis.json_set('user:1', '$', { name: "Alice", age: 25 })
    redis.json_set('user:2', '$', { name: "Bob", age: 30 })
    result = redis.json_mget(['user:1', 'user:2'], '$.name')
    assert_equal ["Alice", "Bob"], result
  end

  def test_json_del
    redis.json_set('test', '$', { a: 1, b: 2 })
    assert_equal 1, redis.json_del('test', '$.a')
    assert_equal({ b: 2 }, redis.json_get('test'))
  end

  def test_json_forget
    redis.json_set('test_forget', '$', { a: 1, b: 2 })
    assert_equal 1, redis.json_forget('test_forget', '$.a')
    assert_equal({ b: 2 }, redis.json_get('test_forget'))
  end

  def test_json_type
    redis.json_set('test', '$', { str: "hello", num: 42, arr: [1, 2], obj: { a: 1 } })
    assert_equal ["string"], redis.json_type('test', '$.str')
    assert_equal ["number"], redis.json_type('test', '$.num')
    assert_equal ["array"], redis.json_type('test', '$.arr')
    assert_equal ["object"], redis.json_type('test', '$.obj')
  end

  def test_json_numincrby
    redis.json_set('test', '$', { num: 10 })
    assert_equal 15, redis.json_numincrby('test', '$.num', 5)
    assert_equal 15, redis.json_get('test', '$.num')
  end

  def test_json_nummultby
    redis.json_set('test', '$', { num: 5 })
    assert_equal 15, redis.json_nummultby('test', '$.num', 3)
    assert_equal 15, redis.json_get('test', '$.num')
  end

  def test_json_strappend
    redis.json_set('test', '$', { str: "hello" })
    assert_equal 11, redis.json_strappend('test', '$.str', " world")
    assert_equal({ str: "hello world" }, redis.json_get('test'))
  end

  def test_json_strlen
    redis.json_set('test', '$', { str: "hello" })
    assert_equal [5], redis.json_strlen('test', '$.str')
  end

  def test_json_arrappend
    redis.json_set('test', '$', { arr: [1, 2] })
    assert_equal [4], redis.json_arrappend('test', '$.arr', 3, 4)
    assert_equal({ arr: [1, 2, 3, 4] }, redis.json_get('test'))
  end

  def test_json_arrindex
    redis.json_set('test', '$', { arr: [1, 2, 3, 2, 1] })
    assert_equal [1], redis.json_arrindex('test', '$.arr', 2)
  end

  def test_json_arrinsert
    redis.json_set('test', '$', { arr: [1, 3] })
    assert_equal [3], redis.json_arrinsert('test', '$.arr', 1, 2)
    assert_equal({ arr: [1, 2, 3] }, redis.json_get('test'))
  end

  def test_json_arrlen
    redis.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal [3], redis.json_arrlen('test', '$.arr')
  end

  def test_json_arrpop
    redis.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal 3, redis.json_arrpop('test', '$.arr', -1)
    assert_equal({ arr: [1, 2] }, redis.json_get('test'))
  end

  def test_json_arrtrim
    redis.json_set('test', '$', { arr: [1, 2, 3, 4, 5] })
    assert_equal [3], redis.json_arrtrim('test', '$.arr', 1, 3)
    assert_equal({ arr: [2, 3, 4] }, redis.json_get('test'))
  end

  def test_json_objkeys
    redis.json_set('test', '$', { a: 1, b: 2, c: 3 })
    keys = redis.json_objkeys('test', '$').first.sort
    assert_equal ["a", "b", "c"], keys
  end

  def test_json_objlen
    redis.json_set('test', '$', { a: 1, b: 2, c: 3 })
    assert_equal [3], redis.json_objlen('test', '$')
  end

  def test_json_mset
    assert_equal "OK", redis.json_mset([
                                         ['user:1', '$', { name: 'John' }],
                                         ['user:2', '$', { name: 'Jane' }]
                                       ])
    assert_equal({ name: 'John' }, redis.json_get('user:1'))
    assert_equal({ name: 'Jane' }, redis.json_get('user:2'))
  end

  def test_json_merge
    redis.json_set('test', '$', { a: 1, b: 2 })
    assert_equal "OK", redis.json_merge('test', '$', { b: 3, c: 4 })
    assert_equal({ a: 1, b: 3, c: 4 }, redis.json_get('test'))
  end

  def test_json_toggle
    redis.json_set('test', '$', { flag: true })
    assert_equal [0], redis.json_toggle('test', '$.flag')
    assert_equal({ flag: false }, redis.json_get('test'))
  end

  def test_json_clear
    redis.json_set('test', '$', { arr: [1, 2, 3], obj: { a: 1 } })
    assert_equal 2, redis.json_clear('test', '$.*')
    result = redis.json_get('test')
    assert_equal [], result[:arr]
    assert_equal({}, result[:obj])
  end
end
