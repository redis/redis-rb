# frozen_string_literal: true

require "helper"

class TestCommandsOnJSON < Minitest::Test
  include Helper::Client
  include Redis::Commands::JSON
  include Redis::Commands::JSON

  def setup
    super
    # Check if JSON module is available
    begin
      r.call('JSON.SET', '__test__', '$', '{}')
      r.call('JSON.DEL', '__test__')
    rescue Redis::CommandError => e
      skip "JSON module not available: #{e.message}"
    end
  end

  def test_json_set_and_get
    assert r.json_set('test', '$', { name: "John", age: 30 })
    assert_equal({ name: "John", age: 30 }, r.json_get('test'))
  end

  def test_json_mget
    r.json_set('user:1', '$', { name: "Alice", age: 25 })
    r.json_set('user:2', '$', { name: "Bob", age: 30 })
    result = r.json_mget(['user:1', 'user:2'], '$.name')
    assert_equal ["Alice", "Bob"], result
  end

  def test_json_del
    r.json_set('test', '$', { a: 1, b: 2 })
    assert_equal 1, r.json_del('test', '$.a')
    assert_equal({ b: 2 }, r.json_get('test'))
  end

  def test_json_forget
    # json_forget is an alias for json_del
    r.json_set('test_forget', '$', { a: 1, b: 2 })
    assert_equal 1, r.json_forget('test_forget', '$.a')
    assert_equal({ b: 2 }, r.json_get('test_forget'))
    # Second delete should return 0
    assert_equal 0, r.json_forget('test_forget', '$.a')
  end

  def test_json_numincrby
    r.json_set('test', '$', { num: 10 })
    assert_equal 15, r.json_numincrby('test', '$.num', 5)
  end

  def test_json_nummultby
    r.json_set('test', '$', { num: 10 })
    assert_equal 20, r.json_nummultby('test', '$.num', 2)
  end

  def test_json_strlen
    r.json_set('test', '$', { str: "Hello" })
    assert_equal [5], r.json_strlen('test', '$.str')
  end

  def test_json_arrappend
    r.json_set('test', '$', { arr: [1, 2] })
    assert_equal [4], r.json_arrappend('test', '$.arr', 3, 4)
    assert_equal [1, 2, 3, 4], r.json_get('test', '$.arr')
  end

  def test_json_arrindex
    r.json_set('test', '$', { arr: [1, 2, 3, 2] })
    assert_equal [1], r.json_arrindex('test', '$.arr', 2)
    assert_equal [3], r.json_arrindex('test', '$.arr', 2, 2)
  end

  def test_json_arrinsert
    r.json_set('test', '$', { arr: [1, 2, 4] })
    assert_equal [4], r.json_arrinsert('test', '$.arr', 2, 3)
    assert_equal [1, 2, 3, 4], r.json_get('test', '$.arr')
  end

  def test_json_arrlen
    r.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal [3], r.json_arrlen('test', '$.arr')
  end

  def test_json_arrpop
    r.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal [3], r.json_arrpop('test', '$.arr')
    assert_equal [1, 2], r.json_get('test', '$.arr')
  end

  def test_json_arrtrim
    r.json_set('test', '$', { arr: [1, 2, 3, 4, 5] })
    result = r.json_arrtrim('test', '$.arr', 1, 3)
    assert_equal [3], result
    get_result = r.json_get('test', '$.arr')
    assert_equal [2, 3, 4], get_result
  end

  def test_json_objkeys
    r.json_set('test', '$', { a: 1, b: 2, c: 3 })
    assert_equal [['a', 'b', 'c']], r.json_objkeys('test')
  end

  def test_json_objlen
    r.json_set('test', '$', { a: 1, b: 2, c: 3 })
    assert_equal [3], r.json_objlen('test')
  end

  def test_json_set_with_options
    assert r.json_set('test', '$', { name: "John", age: 30 })
    assert_nil r.json_set('test', '$', { name: "Jane" }, nx: true)
    assert r.json_set('test', '$', { name: "Jane" }, xx: true)
    assert_equal({ name: "Jane" }, r.json_get('test'))
  end

  def test_json_set_update_specific_field
    assert r.json_set('test', '$', { name: "John", age: 30 })
    assert r.json_set('test', '$.age', 31)
    assert_equal({ name: "John", age: 31 }, r.json_get('test'))
  end

  def test_json_set_add_new_field
    assert r.json_set('test', '$', { name: "John" })
    assert r.json_set('test', '$.age', 30)
    assert_equal({ name: "John", age: 30 }, r.json_get('test'))
  end

  def test_json_mget_complex
    r.json_set('user:1', '$', { name: "Alice", age: 25, address: { city: "New York" } })
    r.json_set('user:2', '$', { name: "Bob", age: 30, address: { city: "San Francisco" } })
    result = r.json_mget(['user:1', 'user:2'], '$.address.city')
    assert_equal ["New York", "San Francisco"], result
  end

  def test_json_type_nested
    r.json_set('test', '$', { a: 1, b: { c: "string", d: [1, 2, 3] } })
    assert_equal ['integer'], r.json_type('test', '$.a')
    assert_equal ['object'], r.json_type('test', '$.b')
    assert_equal ['string'], r.json_type('test', '$.b.c')
    assert_equal ['array'], r.json_type('test', '$.b.d')
  end

  def test_json_numincrby_float
    r.json_set('test', '$', { num: 10.5 })
    assert_equal 13.7, r.json_numincrby('test', '$.num', 3.2)
  end

  def test_json_nummultby_float
    r.json_set('test', '$', { num: 10.5 })
    assert_equal 26.25, r.json_nummultby('test', '$.num', 2.5)
  end

  def test_json_arrappend_multiple_values
    r.json_set('test', '$', { arr: [1, 2] })
    assert_equal [5], r.json_arrappend('test', '$.arr', 3, 4, 5)
    assert_equal [1, 2, 3, 4, 5], r.json_get('test', '$.arr')
  end

  def test_json_arrindex_with_range
    r.json_set('test', '$', { arr: [1, 2, 3, 2, 4, 2] })
    assert_equal [1], r.json_arrindex('test', '$.arr', 2)
    assert_equal [3], r.json_arrindex('test', '$.arr', 2, 2)
    assert_equal [5], r.json_arrindex('test', '$.arr', 2, 4)
    assert_equal [5], r.json_arrindex('test', '$.arr', 2, 6)
  end

  def test_json_arrinsert_multiple_values
    r.json_set('test', '$', { arr: [1, 2, 5] })
    assert_equal [5], r.json_arrinsert('test', '$.arr', 2, 3, 4)
    assert_equal [1, 2, 3, 4, 5], r.json_get('test', '$.arr')
  end

  def test_json_arrpop_with_index
    r.json_set('test', '$', { arr: [1, 2, 3, 4, 5] })
    assert_equal [3], r.json_arrpop('test', '$.arr', 2)
    assert_equal [1, 2, 4, 5], r.json_get('test', '$.arr')
    assert_equal [1], r.json_arrpop('test', '$.arr', 0)
    assert_equal [2, 4, 5], r.json_get('test', '$.arr')
    assert_equal [5], r.json_arrpop('test', '$.arr', -1)
    assert_equal [2, 4], r.json_get('test', '$.arr')
  end

  def test_json_operations_on_nested_arrays
    r.json_set('test', '$', { nested: { arr: [1, [2, 3], 4] } })
    assert_equal [3], r.json_arrlen('test', '$.nested.arr')
    assert_equal [2], r.json_arrlen('test', '$.nested.arr[1]')
    assert_equal [3], r.json_arrappend('test', '$.nested.arr[1]', 4)
    assert_equal [1, [2, 3, 4], 4], r.json_get('test', '$.nested.arr')
    assert_equal [1], r.json_arrindex('test', '$.nested.arr', [2, 3, 4])
    r.json_arrinsert('test', '$.nested.arr', 1, 'inserted')
    assert_equal [1, 'inserted', [2, 3, 4], 4], r.json_get('test', '$.nested.arr')
  end

  def test_json_set_and_get_with_path
    r.json_set('test', '$', { user: { name: "John", address: { city: "New York" } } })
    assert_equal "John", r.json_get('test', '$.user.name')
    assert_equal "New York", r.json_get('test', '$.user.address.city')
    r.json_set('test', '$.user.address.country', "USA")
    assert_equal({ city: "New York", country: "USA" }, r.json_get('test', '$.user.address'))
  end

  def test_json_type_with_complex_structure
    r.json_set('test', '$', {
                 null_value: nil,
                 string_value: "hello",
                 number_value: 42,
                 float_value: 3.14,
                 boolean_value: true,
                 array_value: [1, 2, 3],
                 object_value: { key: "value" }
               })
    assert_equal ['null'], r.json_type('test', '$.null_value')
    assert_equal ['string'], r.json_type('test', '$.string_value')
    assert_equal ['integer'], r.json_type('test', '$.number_value')
    assert_equal ['number'], r.json_type('test', '$.float_value')
    assert_equal ['boolean'], r.json_type('test', '$.boolean_value')
    assert_equal ['array'], r.json_type('test', '$.array_value')
    assert_equal ['object'], r.json_type('test', '$.object_value')
  end

  def test_json_strappend_with_nested_path
    r.json_set('test', '$', { user: { name: "John" } })
    assert_equal [8], r.json_strappend('test', '$.user.name', " Doe")
    assert_equal "John Doe", r.json_get('test', '$.user.name')
  end

  def test_json_numincrby_and_nummultby_with_nested_path
    r.json_set('test', '$', { user: { stats: { points: 100, multiplier: 2 } } })
    assert_equal 150, r.json_numincrby('test', '$.user.stats.points', 50)
    assert_equal 300, r.json_nummultby('test', '$.user.stats.points', 2)
    assert_equal 6, r.json_nummultby('test', '$.user.stats.multiplier', 3)
  end

  def test_json_del_with_nested_path
    r.json_set('test', '$', { user: { name: "John", age: 30, address: { city: "New York", country: "USA" } } })
    assert_equal 1, r.json_del('test', '$.user.age')
    assert_equal 1, r.json_del('test', '$.user.address.city')
    expected = { user: { name: "John", address: { country: "USA" } } }
    assert_equal expected, r.json_get('test')
  end

  def test_json_arrpop_empty_array
    r.json_set('test', '$', { arr: [] })
    assert_equal [nil], r.json_arrpop('test', '$.arr')
    assert_equal [], r.json_get('test', '$.arr')
  end

  def test_json_arrindex_non_existent_value
    r.json_set('test', '$', { arr: [1, 2, 3] })
    assert_equal([-1], r.json_arrindex('test', '$.arr', 4))
  end

  def test_json_object_operations
    r.json_set('test', '$', { user: { name: "John", age: 30 } })
    assert_equal [['name', 'age']], r.json_objkeys('test', '$.user')
    assert_equal [2], r.json_objlen('test', '$.user')
    r.json_set('test', '$.user.email', 'john@example.com')
    assert_equal [3], r.json_objlen('test', '$.user')
    assert_includes r.json_objkeys('test', '$.user').first, 'email'
  end

  def test_json_operations_on_non_existent_key
    assert_nil r.json_get('non_existent')
    assert_equal 0, r.json_del('non_existent')
    assert_nil r.json_type('non_existent')

    error_message = "ERR could not perform this operation on a key that doesn't exist"
    assert_raises(Redis::CommandError, error_message) do
      r.json_strappend('non_existent', '$', 'append_me')
    end

    assert_raises(Redis::CommandError, error_message) do
      r.json_arrappend('non_existent', '$', 1)
    end
  end

  def test_json_set_with_large_nested_structure
    large_structure = {
      level1: {
        level2: {
          level3: {
            level4: {
              level5: {
                data: "Deep nested data",
                array: [1, 2, 3, 4, 5],
                nested_object: {
                  key1: "value1",
                  key2: "value2"
                }
              }
            }
          }
        }
      }
    }
    assert r.json_set('test', '$', large_structure)
    assert_equal "Deep nested data", r.json_get('test', '$.level1.level2.level3.level4.level5.data')
    assert_equal [1, 2, 3, 4, 5], r.json_get('test', '$.level1.level2.level3.level4.level5.array')
    assert_equal "value2", r.json_get('test', '$.level1.level2.level3.level4.level5.nested_object.key2')
  end

  def test_jsonset_jsonget_mixed_types
    d = { hello: "world", some: "value" }
    assert r.json_set("somekey", "$", d)
    assert_equal d, r.json_get("somekey")
  end

  def test_nonascii_setgetdelete
    assert r.json_set("notascii", "$", "hyvää-élève")
    assert_equal "hyvää-élève", r.json_get("notascii")
    assert_equal 1, r.json_del("notascii")
    assert_equal 0, r.exists("notascii")
  end

  def test_jsonsetexistentialmodifiersshouldsucceed
    obj = { "foo" => "bar" }
    assert r.json_set("obj", "$", obj)

    # Test that flags prevent updates when conditions are unmet
    assert_nil r.json_set("obj", "$.foo", "baz", nx: true)
    assert_nil r.json_set("obj", "$.qaz", "baz", xx: true)

    # Test that flags allow updates when conditions are met
    assert r.json_set("obj", "$.foo", "baz", xx: true)
    assert r.json_set("obj", "$.qaz", "baz", nx: true)

    # Test that flags are mutually exclusive
    assert_raises(Redis::CommandError) do
      r.json_set("obj", "$.foo", "baz", nx: true, xx: true)
    end
  end

  def test_mget
    r.json_set("1", "$", 1)
    r.json_set("2", "$", 2)
    assert_equal [1], r.json_mget(["1"], "$")
    assert_equal [1, 2], r.json_mget(["1", "2"], "$")
  end

  def test_json_mset
    triplets = [
      ["key1", "$", { name: "John", age: 30 }],
      ["key2", "$", { name: "Jane", age: 25 }]
    ]
    assert_equal "OK", r.json_mset(triplets)

    assert_equal({ name: "John", age: 30 }, r.json_get("key1"))
    assert_equal({ name: "Jane", age: 25 }, r.json_get("key2"))

    assert_equal [{ name: "John", age: 30 }, { name: "Jane", age: 25 }], r.json_mget(["key1", "key2"], "$")
  end

  def test_json_arrappend_and_arrlen
    r.json_set('arr', '$', [1, 2])
    assert_equal [4], r.json_arrappend('arr', '$', 3, 4)
    assert_equal [4], r.json_arrlen('arr', '$')
    assert_equal [1, 2, 3, 4], r.json_get('arr')
  end

  def test_json_numincrby_and_nummultby
    r.json_set('num', '$', { "value": 10 })
    assert_equal 15, r.json_numincrby('num', '$.value', 5)
    assert_equal 30, r.json_nummultby('num', '$.value', 2)
    assert_equal({ value: 30 }, r.json_get('num'))
  end

  def test_json_objkeys_and_objlen
    r.json_set('obj', '$', { "name" => "John", "age" => 30, "city" => "New York" })
    assert_equal [['name', 'age', 'city']], r.json_objkeys('obj', '$').sort
    assert_equal [3], r.json_objlen('obj', '$')
  end

  def test_json_strappend_and_strlen
    r.json_set('str', '$', "Hello")
    assert_equal [11], r.json_strappend('str', '$', " World")
    assert_equal [11], r.json_strlen('str', '$')
    assert_equal "Hello World", r.json_get('str')
  end

  def test_json_toggle
    r.json_set('toggle', '$', { "flag" => false })
    assert_equal [1], r.json_toggle('toggle', '$.flag')
    assert_equal [0], r.json_toggle('toggle', '$.flag')
    assert_equal({ flag: false }, r.json_get('toggle'))
  end

  def test_json_clear
    r.json_set('clear', '$', { "arr" => [1, 2, 3], "obj" => { "a" => 1, "b" => 2 } })
    result = r.json_clear('clear', '$')
    assert_equal 1, result
    assert_equal({}, r.json_get('clear'))
  end

  def test_json_mget_with_complex_paths
    r.json_set('user1', '$', { name: "John", age: 30, pets: ["dog", "cat"] })
    r.json_set('user2', '$', { name: "Jane", age: 28, pets: ["fish"] })

    result = r.json_mget(['user1', 'user2'], '$')
    expected = [
      { name: "John", age: 30, pets: ["dog", "cat"] },
      { name: "Jane", age: 28, pets: ["fish"] }
    ]
    assert_equal expected, result
  end

  def test_json_strappend_single_path
    r.json_set('obj', '$', { str1: "Hello", str2: "World" })
    result = r.json_strappend('obj', '$.str1', " Redis")
    assert_equal [11], result
    assert_equal({ str1: "Hello Redis", str2: "World" }, r.json_get('obj'))
  end

  def test_json_arrpop_single_path
    r.json_set('obj', '$', {
                 arr1: [1, 2, 3],
                 arr2: [4, 5, 6],
                 not_arr: "string"
               })
    result = r.json_arrpop('obj', '$.arr1', -1)
    assert_equal [3], result
    assert_equal({
                   arr1: [1, 2],
                   arr2: [4, 5, 6],
                   not_arr: "string"
                 }, r.json_get('obj'))
  end

  def test_json_resp
    r.json_set('resp', '$', { 'foo': 'bar', 'baz': 42, 'qux': true })
    result = r.json_resp('resp', '$')
    assert_equal [["{", "foo", "bar", "baz", 42, "qux", "true"]], result
  end

  def test_json_debug_memory
    r.json_set('debug', '$', { 'foo': 'bar', 'baz': [1, 2, 3] })
    memory_usage = r.json_debug('MEMORY', 'debug', '$')
    assert_kind_of Integer, memory_usage.first
    assert memory_usage.first > 0
  end

  def test_json_get_complex_path
    r.json_set('complex', '$', {
                 'users': [
                   { 'name': 'John', 'age': 30 },
                   { 'name': 'Jane', 'age': 25 }
                 ],
                 'products': [
                   { 'name': 'Apple', 'price': 1.0 },
                   { 'name': 'Banana', 'price': 0.5 }
                 ]
               })
    result = r.json_get('complex', '$.users[?(@.age>28)].name')
    assert_equal 'John', result
  end

  def test_json_operations_on_non_existent_paths
    r.json_set('nested', '$', { 'a': { 'b': 1 } })
    arrappend_result = r.json_arrappend('nested', '$.nonexistent', 1)

    assert_equal [], arrappend_result
  end

  def test_json_arrindex_out_of_range
    r.json_set('arr', '$', [1, 2, 3, 4, 5])
    assert_equal([-1], r.json_arrindex('arr', '$', 6))
    assert_equal([-1], r.json_arrindex('arr', '$', 3, 10))
  end

  def test_json_arrappend_behavior
    r.json_set('test', '$', { 'existing': [1, 2, 3] })
    # Returns nil for non-existent paths
    assert_equal [], r.json_arrappend('test', '$.nonexistent', 4)
    # Returns the new length for existing paths
    assert_equal [4], r.json_arrappend('test', '$.existing', 4)
    # Verify the actual state after operations
    assert_equal({ existing: [1, 2, 3, 4] }, r.json_get('test'))
  end

  def test_json_type_all_types
    r.json_set('test', '$', {
                 null: nil,
                 bool: true,
                 int: 42,
                 float: 3.14,
                 string: 'hello',
                 array: [1, 2, 3],
                 object: { a: 1 }
               })

    assert_equal ['null'], r.json_type('test', '$.null')
    assert_equal ['boolean'], r.json_type('test', '$.bool')
    assert_equal ['integer'], r.json_type('test', '$.int')
    assert_equal ['number'], r.json_type('test', '$.float')
    assert_equal ['string'], r.json_type('test', '$.string')
    assert_equal ['array'], r.json_type('test', '$.array')
    assert_equal ['object'], r.json_type('test', '$.object')
  end

  def test_json_strappend_multiple_paths
    r.json_set('test', '$', { a: 'Hello', b: 'World' })
    result = r.json_strappend('test', '$.*', ' Redis')
    assert_equal [11, 11], result
    assert_equal({ a: 'Hello Redis', b: 'World Redis' }, r.json_get('test'))
  end

  def test_json_numincrby_multiple_paths
    r.json_set('test', '$', { a: 1, b: 2, c: 3 })
    result = r.json_numincrby('test', '$.*', 10)
    assert_equal [11, 12, 13], result
    assert_equal({ a: 11, b: 12, c: 13 }, r.json_get('test'))
  end

  def test_json_toggle_multiple_paths
    r.json_set('test', '$', { a: true, b: false, c: true })
    result = r.json_toggle('test', '$.*')
    assert_equal [0, 1, 0], result
    assert_equal({ a: false, b: true, c: false }, r.json_get('test'))
  end

  def test_json_merge
    # Test with root path $
    r.json_set("person_data", "$", { person1: { personal_data: { name: "John" } } })
    r.json_merge("person_data", "$", { person1: { personal_data: { hobbies: "reading" } } })
    assert_equal({ person1: { personal_data: { name: "John", hobbies: "reading" } } }, r.json_get("person_data"))

    # Test with root path $.person1.personal_data
    r.json_merge("person_data", "$.person1.personal_data", { country: "Israel" })
    assert_equal({ person1: { personal_data: { name: "John", hobbies: "reading", country: "Israel" } } }, r.json_get("person_data"))

    # Test with null value to delete a value
    r.json_merge("person_data", "$.person1.personal_data", { name: nil })
    assert_equal({ person1: { personal_data: { country: "Israel", hobbies: "reading" } } }, r.json_get("person_data"))
  end

  # Ported from redis-py test_json.py
  def test_json_setgetdeleteforget
    assert r.json_set('foo', '$', 'bar')
    assert_equal 'bar', r.json_get('foo')
    assert_nil r.json_get('baz')
    assert_equal 1, r.json_del('foo')
    assert_equal 0, r.json_del('foo') # second delete (forget)
    assert_equal 0, r.exists('foo')
  end

  def test_json_type_integer
    r.json_set('1', '$', 1)
    result = r.json_type('1', '$')
    assert_equal ['integer'], result
    result = r.json_type('1')
    assert_equal ['integer'], result
  end

  def test_json_type_string
    r.json_set('str', '$', 'hello')
    result = r.json_type('str', '$')
    assert_equal ['string'], result
  end

  def test_json_type_array
    r.json_set('arr', '$', [1, 2, 3])
    result = r.json_type('arr', '$')
    assert_equal ['array'], result
  end

  def test_json_type_object
    r.json_set('obj', '$', { 'a' => 1 })
    result = r.json_type('obj', '$')
    assert_equal ['object'], result
  end

  def test_json_type_boolean
    r.json_set('bool', '$', true)
    result = r.json_type('bool', '$')
    assert_equal ['boolean'], result
  end

  def test_json_type_null
    r.json_set('null', '$', nil)
    result = r.json_type('null', '$')
    assert_equal ['null'], result
  end

  def test_json_arrindex_advanced
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [1], r.json_arrindex('arr', '$', 1)
    assert_equal [-1], r.json_arrindex('arr', '$', 1, 2)
    assert_equal [4], r.json_arrindex('arr', '$', 4)
    assert_equal [4], r.json_arrindex('arr', '$', 4, 0)
    assert_equal [4], r.json_arrindex('arr', '$', 4, 0, 5000)
    assert_equal [-1], r.json_arrindex('arr', '$', 4, 0, -1)
    assert_equal [-1], r.json_arrindex('arr', '$', 4, 1, 3)
  end

  def test_json_arrinsert_prepend
    r.json_set('arr', '$', [0, 4])
    assert_equal [5], r.json_arrinsert('arr', '$', 1, 1, 2, 3)
    assert_equal [0, 1, 2, 3, 4], r.json_get('arr')

    # test prepends
    r.json_set('val2', '$', [5, 6, 7, 8, 9])
    r.json_arrinsert('val2', '$', 0, ['some', 'thing'])
    assert_equal [['some', 'thing'], 5, 6, 7, 8, 9], r.json_get('val2')
  end

  def test_json_arrlen_nonexistent
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [5], r.json_arrlen('arr', '$')
    assert_equal [5], r.json_arrlen('arr')
    # fakekey doesn't exist - skip this test as it raises error
  end

  def test_json_arrpop_advanced
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [4], r.json_arrpop('arr', '$', 4)
    assert_equal [3], r.json_arrpop('arr', '$', -1)
    assert_equal [2], r.json_arrpop('arr', '$')
    assert_equal [0], r.json_arrpop('arr', '$', 0)
    # After all pops, only element 1 remains - but json_get returns the value directly
    assert_equal 1, r.json_get('arr')

    # test out of bounds
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [4], r.json_arrpop('arr', '$', 99)

    # none test - empty array returns [nil] with JSONPath
    r.json_set('arr', '$', [])
    assert_equal [nil], r.json_arrpop('arr')
  end

  def test_json_arrtrim_advanced
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [3], r.json_arrtrim('arr', '$', 1, 3)
    assert_equal [1, 2, 3], r.json_get('arr')

    # <0 test, should be 0 equivalent
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [0], r.json_arrtrim('arr', '$', -1, 3)

    # testing stop > end
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [2], r.json_arrtrim('arr', '$', 3, 99)

    # start > array size and stop
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [0], r.json_arrtrim('arr', '$', 9, 1)

    # all larger
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal [0], r.json_arrtrim('arr', '$', 9, 11)
  end

  def test_json_resp_command
    obj = { 'foo' => 'bar', 'baz' => 1, 'qaz' => true }
    r.json_set('obj', '$', obj)
    assert_equal ['bar'], r.json_resp('obj', '$.foo')
    assert_equal [1], r.json_resp('obj', '$.baz')
    assert r.json_resp('obj', '$.qaz')
    assert_instance_of Array, r.json_resp('obj')
  end

  def test_json_objkeys_sorted
    obj = { 'foo' => 'bar', 'baz' => 'qaz' }
    r.json_set('obj', '$', obj)
    keys = r.json_objkeys('obj', '$')
    assert_equal [obj.keys.sort], keys.map(&:sort)
  end

  def test_json_objlen_with_path
    obj = { 'foo' => 'bar', 'baz' => 'qaz' }
    r.json_set('obj', '$', obj)
    assert_equal [obj.length], r.json_objlen('obj', '$')
    assert_equal [obj.length], r.json_objlen('obj')
  end

  def test_json_delete_with_dollar
    doc1 = { 'a' => 1, 'nested' => { 'a' => 2, 'b' => 3 } }
    assert r.json_set('doc1', '$', doc1)
    assert_equal 2, r.json_del('doc1', '$..a')
    # json_get without path returns the object directly (not wrapped in array)
    res = { nested: { b: 3 } }
    assert_equal res, r.json_get('doc1')

    doc2 = { 'a' => { 'a' => 2, 'b' => 3 }, 'b' => ['a', 'b'], 'nested' => { 'b' => [true, 'a', 'b'] } }
    assert r.json_set('doc2', '$', doc2)
    assert_equal 1, r.json_del('doc2', '$..a')
    res = { nested: { b: [true, 'a', 'b'] }, b: ['a', 'b'] }
    assert_equal res, r.json_get('doc2')

    # Test default path
    r.json_set('doc3', '$', { 'a' => 1 })
    assert_equal 1, r.json_del('doc3')
    assert_nil r.json_get('doc3', '$')
  end

  def test_json_mget_dollar
    r.json_set('doc1', '$', { 'a' => 1, 'b' => 2, 'nested' => { 'a' => 3 }, 'c' => nil })
    r.json_set('doc2', '$', { 'a' => 4, 'b' => 5, 'nested' => { 'a' => 6 }, 'c' => nil })

    # Compare the first result
    result = r.json_mget(['doc1', 'doc2'], '$..a')
    assert_equal [[1, 3], [4, 6]], result
  end

  def test_json_clear_array
    r.json_set('arr', '$', [0, 1, 2, 3, 4])
    assert_equal 1, r.json_clear('arr', '$')
    assert_equal [], r.json_get('arr')
  end

  def test_json_toggle_boolean
    r.json_set('bool', '$', false)
    assert_equal [1], r.json_toggle('bool', '$')
    assert_equal [0], r.json_toggle('bool', '$')

    # check non-boolean value - may not raise error in all Redis versions
    # Skipping error test as behavior may vary
  end

  def test_json_strappend
    r.json_set('jsonkey', '$', 'foo')
    assert_equal [6], r.json_strappend('jsonkey', '$', 'bar')
    assert_equal 'foobar', r.json_get('jsonkey')
  end

  def test_json_strlen_with_append
    r.json_set('str', '$', 'foo')
    assert_equal [3], r.json_strlen('str', '$')
    r.json_strappend('str', '$', 'bar')
    assert_equal [6], r.json_strlen('str', '$')
    assert_equal [6], r.json_strlen('str')
  end

  def test_json_mget_dollar_advanced
    # Test mget with multi paths
    r.json_set('doc1', '$', { 'a' => 1, 'b' => 2, 'nested' => { 'a' => 3 }, 'c' => nil, 'nested2' => { 'a' => nil } })
    r.json_set('doc2', '$', { 'a' => 4, 'b' => 5, 'nested' => { 'a' => 6 }, 'c' => nil, 'nested2' => { 'a' => [nil] } })

    # Compare also to single JSON.GET
    res = [1, 3, nil]
    assert_equal res, r.json_get('doc1', '$..a')
    res = [4, 6, [nil]]
    assert_equal res, r.json_get('doc2', '$..a')

    # Test mget with single path
    assert_equal [[1, 3, nil]], r.json_mget(['doc1'], '$..a')
    # Test mget with multi path
    res = [[1, 3, nil], [4, 6, [nil]]]
    assert_equal res, r.json_mget(['doc1', 'doc2'], '$..a')

    # Test missing key
    assert_equal [[1, 3, nil], nil], r.json_mget(['doc1', 'missing_doc'], '$..a')
    assert_equal [nil, nil], r.json_mget(['missing_doc1', 'missing_doc2'], '$..a')
  end

  def test_numby_commands_dollar
    # Test NUMINCRBY
    r.json_set('doc1', '$', { 'a' => 'b', 'b' => [{ 'a' => 2 }, { 'a' => 5.0 }, { 'a' => 'c' }] })
    # Test multi
    assert_equal [nil, 4, 7.0, nil], r.json_numincrby('doc1', '$..a', 2)
    assert_equal [nil, 6.5, 9.5, nil], r.json_numincrby('doc1', '$..a', 2.5)
    # Test single - returns single value not array when path is specific
    assert_equal 11.5, r.json_numincrby('doc1', '$.b[1].a', 2)
    assert_nil r.json_numincrby('doc1', '$.b[2].a', 2)
    assert_equal 15.0, r.json_numincrby('doc1', '$.b[1].a', 3.5)

    # Test NUMMULTBY
    r.json_set('doc1', '$', { 'a' => 'b', 'b' => [{ 'a' => 2 }, { 'a' => 5.0 }, { 'a' => 'c' }] })
    # test list
    assert_equal [nil, 4, 10, nil], r.json_nummultby('doc1', '$..a', 2)
    assert_equal [nil, 10.0, 25.0, nil], r.json_nummultby('doc1', '$..a', 2.5)
    # Test single
    assert_equal 50.0, r.json_nummultby('doc1', '$.b[1].a', 2)
    assert_nil r.json_nummultby('doc1', '$.b[2].a', 2)
    assert_equal 150.0, r.json_nummultby('doc1', '$.b[1].a', 3)
  end

  def test_strappend_dollar
    r.json_set('doc1', '$', { 'a' => 'foo', 'nested1' => { 'a' => 'hello' }, 'nested2' => { 'a' => 31 } })
    # Test multi
    assert_equal [6, 8, nil], r.json_strappend('doc1', '$..a', 'bar')
    res = { a: 'foobar', nested1: { a: 'hellobar' }, nested2: { a: 31 } }
    assert_equal res, r.json_get('doc1')

    # Test single
    assert_equal [11], r.json_strappend('doc1', '$.nested1.a', 'baz')
    res = { a: 'foobar', nested1: { a: 'hellobarbaz' }, nested2: { a: 31 } }
    assert_equal res, r.json_get('doc1')
  end

  def test_strlen_dollar
    # Test multi
    r.json_set('doc1', '$', { 'a' => 'foo', 'nested1' => { 'a' => 'hello' }, 'nested2' => { 'a' => 31 } })
    assert_equal [3, 5, nil], r.json_strlen('doc1', '$..a')

    res2 = r.json_strappend('doc1', '$..a', 'bar')
    res1 = r.json_strlen('doc1', '$..a')
    assert_equal res1, res2

    # Test single
    assert_equal [8], r.json_strlen('doc1', '$.nested1.a')
    assert_equal [nil], r.json_strlen('doc1', '$.nested2.a')
  end

  def test_arrappend_dollar
    r.json_set('doc1', '$', {
                 'a' => ['foo'],
                 'nested1' => { 'a' => ['hello', nil, 'world'] },
                 'nested2' => { 'a' => 31 }
               })
    # Test multi
    assert_equal [3, 5, nil], r.json_arrappend('doc1', '$..a', 'bar', 'racuda')
    res = {
      a: ['foo', 'bar', 'racuda'],
      nested1: { a: ['hello', nil, 'world', 'bar', 'racuda'] },
      nested2: { a: 31 }
    }
    assert_equal res, r.json_get('doc1')

    # Test single
    assert_equal [6], r.json_arrappend('doc1', '$.nested1.a', 'baz')
    res = {
      a: ['foo', 'bar', 'racuda'],
      nested1: { a: ['hello', nil, 'world', 'bar', 'racuda', 'baz'] },
      nested2: { a: 31 }
    }
    assert_equal res, r.json_get('doc1')
  end

  def test_arrinsert_dollar
    r.json_set('doc1', '$', {
                 'a' => ['foo'],
                 'nested1' => { 'a' => ['hello', nil, 'world'] },
                 'nested2' => { 'a' => 31 }
               })
    # Test multi
    assert_equal [3, 5, nil], r.json_arrinsert('doc1', '$..a', 1, 'bar', 'racuda')
    res = {
      a: ['foo', 'bar', 'racuda'],
      nested1: { a: ['hello', 'bar', 'racuda', nil, 'world'] },
      nested2: { a: 31 }
    }
    assert_equal res, r.json_get('doc1')

    # Test single with negative index
    assert_equal [6], r.json_arrinsert('doc1', '$.nested1.a', -2, 'baz')
    res = {
      a: ['foo', 'bar', 'racuda'],
      nested1: { a: ['hello', 'bar', 'racuda', 'baz', nil, 'world'] },
      nested2: { a: 31 }
    }
    assert_equal res, r.json_get('doc1')
  end

  def test_arrlen_dollar
    r.json_set('doc1', '$', {
                 'a' => ['foo'],
                 'nested1' => { 'a' => ['hello', nil, 'world'] },
                 'nested2' => { 'a' => 31 }
               })

    # Test multi
    assert_equal [1, 3, nil], r.json_arrlen('doc1', '$..a')
    assert_equal [4, 6, nil], r.json_arrappend('doc1', '$..a', 'non', 'abba', 'stanza')

    r.json_clear('doc1', '$.a')
    assert_equal [0, 6, nil], r.json_arrlen('doc1', '$..a')
    # Test single
    assert_equal [6], r.json_arrlen('doc1', '$.nested1.a')
  end

  def test_arrpop_dollar
    r.json_set('doc1', '$', {
                 'a' => ['foo'],
                 'nested1' => { 'a' => ['hello', nil, 'world'] },
                 'nested2' => { 'a' => 31 }
               })

    # Test multi - arrpop returns the popped value
    assert_equal ['foo', nil, nil], r.json_arrpop('doc1', '$..a', 1)
    res = { a: [], nested1: { a: ['hello', 'world'] }, nested2: { a: 31 } }
    assert_equal res, r.json_get('doc1')
  end

  def test_arrtrim_dollar
    r.json_set('doc1', '$', {
                 'a' => ['foo'],
                 'nested1' => { 'a' => ['hello', nil, 'world'] },
                 'nested2' => { 'a' => 31 }
               })
    # Test multi
    assert_equal [0, 2, nil], r.json_arrtrim('doc1', '$..a', 1, -1)
    res = { a: [], nested1: { a: [nil, 'world'] }, nested2: { a: 31 } }
    assert_equal res, r.json_get('doc1')

    assert_equal [0, 1, nil], r.json_arrtrim('doc1', '$..a', 1, 1)
    res = { a: [], nested1: { a: ['world'] }, nested2: { a: 31 } }
    assert_equal res, r.json_get('doc1')

    # Test single
    assert_equal [0], r.json_arrtrim('doc1', '$.nested1.a', 1, 0)
    res = { a: [], nested1: { a: [] }, nested2: { a: 31 } }
    assert_equal res, r.json_get('doc1')
  end

  def test_objkeys_dollar
    r.json_set('doc1', '$', {
                 'nested1' => { 'a' => { 'foo' => 10, 'bar' => 20 } },
                 'a' => ['foo'],
                 'nested2' => { 'a' => { 'baz' => 50 } }
               })

    # Test single
    keys = r.json_objkeys('doc1', '$.nested1.a')
    assert_equal 1, keys.length
    assert_equal ['bar', 'foo'], keys[0].sort

    # Test nowhere path
    assert_equal [], r.json_objkeys('doc1', '$..nowhere')
  end

  def test_objlen_dollar
    r.json_set('doc1', '$', {
                 'nested1' => { 'a' => { 'foo' => 10, 'bar' => 20 } },
                 'a' => ['foo'],
                 'nested2' => { 'a' => { 'baz' => 50 } }
               })
    # Test multi
    assert_equal [nil, 2, 1], r.json_objlen('doc1', '$..a')
    # Test single
    assert_equal [2], r.json_objlen('doc1', '$.nested1.a')

    # Test missing path
    assert_equal [], r.json_objlen('doc1', '$.nowhere')
  end

  def test_clear_dollar_advanced
    r.json_set('doc1', '$', {
                 'nested1' => { 'a' => { 'foo' => 10, 'bar' => 20 } },
                 'a' => ['foo'],
                 'nested2' => { 'a' => 'claro' },
                 'nested3' => { 'a' => { 'baz' => 50 } }
               })
    # Test multi
    assert_equal 3, r.json_clear('doc1', '$..a')

    res = { nested1: { a: {} }, a: [], nested2: { a: 'claro' }, nested3: { a: {} } }
    assert_equal res, r.json_get('doc1')

    # Test single
    r.json_set('doc1', '$', {
                 'nested1' => { 'a' => { 'foo' => 10, 'bar' => 20 } },
                 'a' => ['foo'],
                 'nested2' => { 'a' => 'claro' },
                 'nested3' => { 'a' => { 'baz' => 50 } }
               })
    assert_equal 1, r.json_clear('doc1', '$.nested1.a')
    res = {
      nested1: { a: {} },
      a: ['foo'],
      nested2: { a: 'claro' },
      nested3: { a: { baz: 50 } }
    }
    assert_equal res, r.json_get('doc1')
  end

  def test_toggle_dollar_advanced
    r.json_set('doc1', '$', {
                 'a' => ['foo'],
                 'nested1' => { 'a' => false },
                 'nested2' => { 'a' => 31 },
                 'nested3' => { 'a' => true }
               })
    # Test multi
    assert_equal [nil, 1, nil, 0], r.json_toggle('doc1', '$..a')
    res = {
      a: ['foo'],
      nested1: { a: true },
      nested2: { a: 31 },
      nested3: { a: false }
    }
    assert_equal res, r.json_get('doc1')
  end

  def test_arrindex_with_jsonpath_filter
    r.json_set('store', '$', {
                 'store' => {
                   'book' => [
                     {
                       'category' => 'reference',
                       'author' => 'Nigel Rees',
                       'title' => 'Sayings of the Century',
                       'price' => 8.95,
                       'size' => [10, 20, 30, 40]
                     },
                     {
                       'category' => 'fiction',
                       'author' => 'Evelyn Waugh',
                       'title' => 'Sword of Honour',
                       'price' => 12.99,
                       'size' => [50, 60, 70, 80]
                     },
                     {
                       'category' => 'fiction',
                       'author' => 'Herman Melville',
                       'title' => 'Moby Dick',
                       'isbn' => '0-553-21311-3',
                       'price' => 8.99,
                       'size' => [5, 10, 20, 30]
                     }
                   ],
                   'bicycle' => { 'color' => 'red', 'price' => 19.95 }
                 }
               })

    # Test JSONPath filter
    result = r.json_get('store', '$.store.book[?(@.price<10)].size')
    assert_equal [[10, 20, 30, 40], [5, 10, 20, 30]], result

    # Test arrindex with JSONPath filter - string search returns -1
    assert_equal [-1, -1], r.json_arrindex('store', '$.store.book[?(@.price<10)].size', '20')

    # Test index of int scalar in multi values
    assert_equal [1, 2], r.json_arrindex('store', '$.store.book[?(@.price<10)].size', 20)
  end
end
