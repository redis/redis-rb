# frozen_string_literal: true

module Lint
  module JSON
    def setup
      super
      # Check if JSON module is available
      begin
        r.json_set('__test__', '$', {})
        r.json_del('__test__')
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
      assert_equal 0, r.json_forget('test_forget', '$.a')
    end

    def test_json_type
      r.json_set('test', '$', { str: "hello", num: 42, arr: [1, 2], obj: { a: 1 } })
      assert_equal ["string"], r.json_type('test', '$.str')
      assert_equal ["integer"], r.json_type('test', '$.num')
      assert_equal ["array"], r.json_type('test', '$.arr')
      assert_equal ["object"], r.json_type('test', '$.obj')
    end

    def test_json_numincrby
      r.json_set('test', '$', { num: 10 })
      assert_equal [15], r.json_numincrby('test', '$.num', 5)
      assert_equal [15], r.json_get('test', '$.num')
    end

    def test_json_nummultby
      r.json_set('test', '$', { num: 5 })
      assert_equal [15], r.json_nummultby('test', '$.num', 3)
      assert_equal [15], r.json_get('test', '$.num')
    end

    def test_json_strappend
      r.json_set('test', '$', { str: "hello" })
      assert_equal [11], r.json_strappend('test', '$.str', " world")
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
      assert_equal [3], r.json_arrpop('test', '$.arr', -1)
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

    def test_json_set_with_options
      assert r.json_set('test', '$', { name: "John", age: 30 })
      assert_nil r.json_set('test', '$', { name: "Jane" }, nx: true)
      assert r.json_set('test', '$', { name: "Jane" }, xx: true)
      assert_equal({ name: "Jane" }, r.json_get('test'))
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
      assert_equal [13.7], r.json_numincrby('test', '$.num', 3.2)
    end

    def test_json_nummultby_float
      r.json_set('test', '$', { num: 10.5 })
      assert_equal [26.25], r.json_nummultby('test', '$.num', 2.5)
    end

    def test_json_arrpop_with_index
      r.json_set('test', '$', { arr: [1, 2, 3, 4, 5] })
      assert_equal [3], r.json_arrpop('test', '$.arr', 2)
      assert_equal [[1, 2, 4, 5]], r.json_get('test', '$.arr')
    end

    def test_json_arrpop_empty_array
      r.json_set('test', '$', { arr: [] })
      assert_equal [nil], r.json_arrpop('test', '$.arr')
      assert_equal [[]], r.json_get('test', '$.arr')
    end

    def test_json_arrindex_non_existent_value
      r.json_set('test', '$', { arr: [1, 2, 3] })
      assert_equal([-1], r.json_arrindex('test', '$.arr', 4))
    end

    def test_json_operations_on_non_existent_key
      assert_nil r.json_get('non_existent')
      assert_equal 0, r.json_del('non_existent')
      assert_nil r.json_type('non_existent')
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

    def test_json_toggle_multiple_paths
      r.json_set('test', '$', { a: true, b: false, c: true })
      result = r.json_toggle('test', '$.*')
      assert_equal [0, 1, 0], result
      assert_equal({ a: false, b: true, c: false }, r.json_get('test'))
    end

    def test_json_merge_nested
      r.json_set("person_data", "$", { person1: { personal_data: { name: "John" } } })
      r.json_merge("person_data", "$", { person1: { personal_data: { hobbies: "reading" } } })
      assert_equal({ person1: { personal_data: { name: "John", hobbies: "reading" } } }, r.json_get("person_data"))

      r.json_merge("person_data", "$.person1.personal_data", { country: "Israel" })
      assert_equal({ person1: { personal_data: { name: "John", hobbies: "reading", country: "Israel" } } }, r.json_get("person_data"))

      r.json_merge("person_data", "$.person1.personal_data", { name: nil })
      assert_equal({ person1: { personal_data: { country: "Israel", hobbies: "reading" } } }, r.json_get("person_data"))
    end

    def test_json_setgetdeleteforget
      assert r.json_set('foo', '$', 'bar')
      assert_equal 'bar', r.json_get('foo')
      assert_nil r.json_get('baz')
      assert_equal 1, r.json_del('foo')
      assert_equal 0, r.json_del('foo')
      assert_equal 0, r.exists('foo')
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

      r.json_set('val2', '$', [5, 6, 7, 8, 9])
      r.json_arrinsert('val2', '$', 0, ['some', 'thing'])
      assert_equal [['some', 'thing'], 5, 6, 7, 8, 9], r.json_get('val2')
    end

    def test_json_arrpop_advanced
      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [4], r.json_arrpop('arr', '$', 4)
      assert_equal [3], r.json_arrpop('arr', '$', -1)
      assert_equal [2], r.json_arrpop('arr', '$')
      assert_equal [0], r.json_arrpop('arr', '$', 0)
      assert_equal [1], r.json_get('arr')

      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [4], r.json_arrpop('arr', '$', 99)

      r.json_set('arr', '$', [])
      assert_equal [nil], r.json_arrpop('arr')
    end

    def test_json_arrtrim_advanced
      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [3], r.json_arrtrim('arr', '$', 1, 3)
      assert_equal [1, 2, 3], r.json_get('arr')

      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [0], r.json_arrtrim('arr', '$', -1, 3)

      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [2], r.json_arrtrim('arr', '$', 3, 99)

      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [0], r.json_arrtrim('arr', '$', 9, 1)

      r.json_set('arr', '$', [0, 1, 2, 3, 4])
      assert_equal [0], r.json_arrtrim('arr', '$', 9, 11)
    end

    def test_json_delete_with_dollar
      doc1 = { 'a' => 1, 'nested' => { 'a' => 2, 'b' => 3 } }
      assert r.json_set('doc1', '$', doc1)
      assert_equal 2, r.json_del('doc1', '$..a')
      res = { nested: { b: 3 } }
      assert_equal res, r.json_get('doc1')

      doc2 = { 'a' => { 'a' => 2, 'b' => 3 }, 'b' => ['a', 'b'], 'nested' => { 'b' => [true, 'a', 'b'] } }
      assert r.json_set('doc2', '$', doc2)
      assert_equal 1, r.json_del('doc2', '$..a')
      res = { nested: { b: [true, 'a', 'b'] }, b: ['a', 'b'] }
      assert_equal res, r.json_get('doc2')

      r.json_set('doc3', '$', { 'a' => 1 })
      assert_equal 1, r.json_del('doc3')
      assert_nil r.json_get('doc3', '$')
    end

    def test_numby_commands_dollar
      r.json_set('doc1', '$', { 'a' => 'b', 'b' => [{ 'a' => 2 }, { 'a' => 5.0 }, { 'a' => 'c' }] })
      assert_equal [nil, 4, 7.0, nil], r.json_numincrby('doc1', '$..a', 2)
      assert_equal [nil, 6.5, 9.5, nil], r.json_numincrby('doc1', '$..a', 2.5)
      assert_equal [11.5], r.json_numincrby('doc1', '$.b[1].a', 2)
      assert_equal [nil], r.json_numincrby('doc1', '$.b[2].a', 2)
      assert_equal [15.0], r.json_numincrby('doc1', '$.b[1].a', 3.5)

      r.json_set('doc1', '$', { 'a' => 'b', 'b' => [{ 'a' => 2 }, { 'a' => 5.0 }, { 'a' => 'c' }] })
      assert_equal [nil, 4, 10, nil], r.json_nummultby('doc1', '$..a', 2)
      assert_equal [nil, 10.0, 25.0, nil], r.json_nummultby('doc1', '$..a', 2.5)
      assert_equal [50.0], r.json_nummultby('doc1', '$.b[1].a', 2)
      assert_equal [nil], r.json_nummultby('doc1', '$.b[2].a', 2)
      assert_equal [150.0], r.json_nummultby('doc1', '$.b[1].a', 3)
    end

    def test_strappend_dollar
      r.json_set('doc1', '$', { 'a' => 'foo', 'nested1' => { 'a' => 'hello' }, 'nested2' => { 'a' => 31 } })
      assert_equal [6, 8, nil], r.json_strappend('doc1', '$..a', 'bar')
      res = { a: 'foobar', nested1: { a: 'hellobar' }, nested2: { a: 31 } }
      assert_equal res, r.json_get('doc1')

      assert_equal [11], r.json_strappend('doc1', '$.nested1.a', 'baz')
      res = { a: 'foobar', nested1: { a: 'hellobarbaz' }, nested2: { a: 31 } }
      assert_equal res, r.json_get('doc1')
    end

    def test_strlen_dollar
      r.json_set('doc1', '$', { 'a' => 'foo', 'nested1' => { 'a' => 'hello' }, 'nested2' => { 'a' => 31 } })
      assert_equal [3, 5, nil], r.json_strlen('doc1', '$..a')

      res2 = r.json_strappend('doc1', '$..a', 'bar')
      res1 = r.json_strlen('doc1', '$..a')
      assert_equal res1, res2

      assert_equal [8], r.json_strlen('doc1', '$.nested1.a')
      assert_equal [nil], r.json_strlen('doc1', '$.nested2.a')
    end

    def test_arrappend_dollar
      r.json_set('doc1', '$', {
                   'a' => ['foo'],
                   'nested1' => { 'a' => ['hello', nil, 'world'] },
                   'nested2' => { 'a' => 31 }
                 })
      assert_equal [3, 5, nil], r.json_arrappend('doc1', '$..a', 'bar', 'racuda')
      res = {
        a: ['foo', 'bar', 'racuda'],
        nested1: { a: ['hello', nil, 'world', 'bar', 'racuda'] },
        nested2: { a: 31 }
      }
      assert_equal res, r.json_get('doc1')

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
      assert_equal [3, 5, nil], r.json_arrinsert('doc1', '$..a', 1, 'bar', 'racuda')
      res = {
        a: ['foo', 'bar', 'racuda'],
        nested1: { a: ['hello', 'bar', 'racuda', nil, 'world'] },
        nested2: { a: 31 }
      }
      assert_equal res, r.json_get('doc1')

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

      assert_equal [1, 3, nil], r.json_arrlen('doc1', '$..a')
      assert_equal [4, 6, nil], r.json_arrappend('doc1', '$..a', 'non', 'abba', 'stanza')

      r.json_clear('doc1', '$.a')
      assert_equal [0, 6, nil], r.json_arrlen('doc1', '$..a')
      assert_equal [6], r.json_arrlen('doc1', '$.nested1.a')
    end

    def test_arrpop_dollar
      r.json_set('doc1', '$', {
                   'a' => ['foo'],
                   'nested1' => { 'a' => ['hello', nil, 'world'] },
                   'nested2' => { 'a' => 31 }
                 })

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
      assert_equal [0, 2, nil], r.json_arrtrim('doc1', '$..a', 1, -1)
      res = { a: [], nested1: { a: [nil, 'world'] }, nested2: { a: 31 } }
      assert_equal res, r.json_get('doc1')

      assert_equal [0, 1, nil], r.json_arrtrim('doc1', '$..a', 1, 1)
      res = { a: [], nested1: { a: ['world'] }, nested2: { a: 31 } }
      assert_equal res, r.json_get('doc1')

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

      keys = r.json_objkeys('doc1', '$.nested1.a')
      assert_equal 1, keys.length
      assert_equal ['bar', 'foo'], keys[0].sort

      assert_equal [], r.json_objkeys('doc1', '$..nowhere')
    end

    def test_objlen_dollar
      r.json_set('doc1', '$', {
                   'nested1' => { 'a' => { 'foo' => 10, 'bar' => 20 } },
                   'a' => ['foo'],
                   'nested2' => { 'a' => { 'baz' => 50 } }
                 })
      assert_equal [nil, 2, 1], r.json_objlen('doc1', '$..a')
      assert_equal [2], r.json_objlen('doc1', '$.nested1.a')

      assert_equal [], r.json_objlen('doc1', '$.nowhere')
    end

    def test_clear_dollar_advanced
      r.json_set('doc1', '$', {
                   'nested1' => { 'a' => { 'foo' => 10, 'bar' => 20 } },
                   'a' => ['foo'],
                   'nested2' => { 'a' => 'claro' },
                   'nested3' => { 'a' => { 'baz' => 50 } }
                 })
      assert_equal 3, r.json_clear('doc1', '$..a')

      res = { nested1: { a: {} }, a: [], nested2: { a: 'claro' }, nested3: { a: {} } }
      assert_equal res, r.json_get('doc1')

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
      assert_equal [nil, 1, nil, 0], r.json_toggle('doc1', '$..a')
      res = {
        a: ['foo'],
        nested1: { a: true },
        nested2: { a: 31 },
        nested3: { a: false }
      }
      assert_equal res, r.json_get('doc1')
    end
  end
end
