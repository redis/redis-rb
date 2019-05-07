# frozen_string_literal: true

module Lint
  module Streams
    MIN_REDIS_VERSION = '4.9.0'
    ENTRY_ID_FORMAT = /\d+-\d+/

    def setup
      super
      omit_version(MIN_REDIS_VERSION)
    end

    def test_xinfo_with_stream_subcommand
      redis.xadd('s1', f: 'v1')
      redis.xadd('s1', f: 'v2')
      redis.xadd('s1', f: 'v3')
      redis.xadd('s1', f: 'v4')
      redis.xgroup(:create, 's1', 'g1', '$')

      actual = redis.xinfo(:stream, 's1')

      assert_match ENTRY_ID_FORMAT, actual['last-generated-id']
      assert_equal 4, actual['length']
      assert_equal 1, actual['groups']
      assert_equal true, actual.key?('radix-tree-keys')
      assert_equal true, actual.key?('radix-tree-nodes')
      assert_kind_of Array, actual['first-entry']
      assert_kind_of Array, actual['last-entry']
    end

    def test_xinfo_with_groups_subcommand
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')

      actual = redis.xinfo(:groups, 's1').first

      assert_equal 0, actual['consumers']
      assert_equal 0, actual['pending']
      assert_equal 'g1', actual['name']
      assert_match ENTRY_ID_FORMAT, actual['last-delivered-id']
    end

    def test_xinfo_with_consumers_subcommand
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')
      assert_equal [], redis.xinfo(:consumers, 's1', 'g1')
    end

    def test_xinfo_with_invalid_arguments
      assert_raises(Redis::CommandError) { redis.xinfo('', '', '') }
      assert_raises(Redis::CommandError) { redis.xinfo(nil, nil, nil) }
      assert_raises(Redis::CommandError) { redis.xinfo(:stream, nil) }
      assert_raises(Redis::CommandError) { redis.xinfo(:groups, nil) }
      assert_raises(Redis::CommandError) { redis.xinfo(:consumers, nil) }
      assert_raises(Redis::CommandError) { redis.xinfo(:consumers, 's1', nil) }
    end

    def test_xadd_with_entry_as_splatted_params
      assert_match ENTRY_ID_FORMAT, redis.xadd('s1', f1: 'v1', f2: 'v2')
    end

    def test_xadd_with_entry_as_a_hash_literal
      entry = { f1: 'v1', f2: 'v2' }
      assert_match ENTRY_ID_FORMAT, redis.xadd('s1', entry)
    end

    def test_xadd_with_entry_id_option
      entry_id = "#{Time.now.strftime('%s%L')}-14"
      assert_equal entry_id, redis.xadd('s1', { f1: 'v1', f2: 'v2' }, id: entry_id)
    end

    def test_xadd_with_invalid_entry_id_option
      entry_id = 'invalid-format-entry-id'
      assert_raises(Redis::CommandError, 'ERR Invalid stream ID specified as stream command argument') do
        redis.xadd('s1', { f1: 'v1', f2: 'v2' }, id: entry_id)
      end
    end

    def test_xadd_with_old_entry_id_option
      redis.xadd('s1', { f1: 'v1', f2: 'v2' }, id: '0-1')
      err_msg = 'ERR The ID specified in XADD is equal or smaller than the target stream top item'
      assert_raises(Redis::CommandError, err_msg) do
        redis.xadd('s1', { f1: 'v1', f2: 'v2' }, id: '0-0')
      end
    end

    def test_xadd_with_maxlen_and_approximate_option
      actual = redis.xadd('s1', { f1: 'v1', f2: 'v2' }, maxlen: 2, approximate: true)
      assert_match ENTRY_ID_FORMAT, actual
    end

    def test_xadd_with_invalid_arguments
      assert_raises(Redis::CommandError) { redis.xadd(nil, {}) }
      assert_raises(Redis::CommandError) { redis.xadd('', {}) }
      assert_raises(Redis::CommandError) { redis.xadd('s1', {}) }
    end

    def test_xtrim
      redis.xadd('s1', f: 'v1')
      redis.xadd('s1', f: 'v2')
      redis.xadd('s1', f: 'v3')
      redis.xadd('s1', f: 'v4')
      assert_equal 2, redis.xtrim('s1', 2)
    end

    def test_xtrim_with_approximate_option
      redis.xadd('s1', f: 'v1')
      redis.xadd('s1', f: 'v2')
      redis.xadd('s1', f: 'v3')
      redis.xadd('s1', f: 'v4')
      assert_equal 0, redis.xtrim('s1', 2, approximate: true)
    end

    def test_xtrim_with_not_existed_stream
      assert_equal 0, redis.xtrim('not-existed-stream', 2)
    end

    def test_xtrim_with_invalid_arguments
      assert_equal 0, redis.xtrim('', '')
      assert_equal 0, redis.xtrim(nil, nil)
      assert_equal 0, redis.xtrim('s1', 0)
      assert_equal 0, redis.xtrim('s1', -1, approximate: true)
    end

    def test_xdel_with_splatted_entry_ids
      redis.xadd('s1', { f: '1' }, id: '0-1')
      redis.xadd('s1', { f: '2' }, id: '0-2')
      assert_equal 2, redis.xdel('s1', '0-1', '0-2', '0-3')
    end

    def test_xdel_with_arrayed_entry_ids
      redis.xadd('s1', { f: '1' }, id: '0-1')
      assert_equal 1, redis.xdel('s1', ['0-1', '0-2'])
    end

    def test_xdel_with_invalid_entry_ids
      assert_equal 0, redis.xdel('s1', 'invalid_format')
    end

    def test_xdel_with_invalid_arguments
      assert_equal 0, redis.xdel(nil, nil)
      assert_equal 0, redis.xdel(nil, [nil])
      assert_equal 0, redis.xdel('', '')
      assert_equal 0, redis.xdel('', [''])
      assert_raises(Redis::CommandError) { redis.xdel('s1', []) }
    end

    def test_xrange
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')

      actual = redis.xrange('s1')

      assert_equal %w(v1 v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xrange_with_start_option
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrange('s1', '0-2')

      assert_equal %w(0-2 0-3), actual.map(&:first)
    end

    def test_xrange_with_end_option
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrange('s1', '-', '0-2')
      assert_equal %w(0-1 0-2), actual.map(&:first)
    end

    def test_xrange_with_start_and_end_options
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrange('s1', '0-2', '0-2')

      assert_equal %w(0-2), actual.map(&:first)
    end

    def test_xrange_with_incomplete_entry_id_options
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '1-1')
      redis.xadd('s1', { f: 'v' }, id: '2-1')

      actual = redis.xrange('s1', '0', '1')

      assert_equal 2, actual.size
      assert_equal %w(0-1 1-1), actual.map(&:first)
    end

    def test_xrange_with_count_option
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrange('s1', count: 2)

      assert_equal %w(0-1 0-2), actual.map(&:first)
    end

    def test_xrange_with_not_existed_stream_key
      assert_equal([], redis.xrange('not-existed'))
    end

    def test_xrange_with_invalid_entry_id_options
      assert_raises(Redis::CommandError) { redis.xrange('s1', 'invalid', 'invalid') }
    end

    def test_xrange_with_invalid_arguments
      assert_equal([], redis.xrange(nil))
      assert_equal([], redis.xrange(''))
    end

    def test_xrevrange
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')

      actual = redis.xrevrange('s1')

      assert_equal %w(0-3 0-2 0-1), actual.map(&:first)
      assert_equal %w(v3 v2 v1), actual.map { |i| i.last['f'] }
    end

    def test_xrevrange_with_start_option
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrevrange('s1', '+', '0-2')

      assert_equal %w(0-3 0-2), actual.map(&:first)
    end

    def test_xrevrange_with_end_option
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrevrange('s1', '0-2')

      assert_equal %w(0-2 0-1), actual.map(&:first)
    end

    def test_xrevrange_with_start_and_end_options
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrevrange('s1', '0-2', '0-2')

      assert_equal %w(0-2), actual.map(&:first)
    end

    def test_xrevrange_with_incomplete_entry_id_options
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '1-1')
      redis.xadd('s1', { f: 'v' }, id: '2-1')

      actual = redis.xrevrange('s1', '1', '0')

      assert_equal 2, actual.size
      assert_equal '1-1', actual.first.first
    end

    def test_xrevrange_with_count_option
      redis.xadd('s1', { f: 'v' }, id: '0-1')
      redis.xadd('s1', { f: 'v' }, id: '0-2')
      redis.xadd('s1', { f: 'v' }, id: '0-3')

      actual = redis.xrevrange('s1', count: 2)

      assert_equal 2, actual.size
      assert_equal '0-3', actual.first.first
    end

    def test_xrevrange_with_not_existed_stream_key
      assert_equal([], redis.xrevrange('not-existed'))
    end

    def test_xrevrange_with_invalid_entry_id_options
      assert_raises(Redis::CommandError) { redis.xrevrange('s1', 'invalid', 'invalid') }
    end

    def test_xrevrange_with_invalid_arguments
      assert_equal([], redis.xrevrange(nil))
      assert_equal([], redis.xrevrange(''))
    end

    def test_xlen
      redis.xadd('s1', f: 'v1')
      redis.xadd('s1', f: 'v2')
      assert_equal 2, redis.xlen('s1')
    end

    def test_xlen_with_not_existed_key
      assert_equal 0, redis.xlen('not-existed')
    end

    def test_xlen_with_invalid_key
      assert_equal 0, redis.xlen(nil)
      assert_equal 0, redis.xlen('')
    end

    def test_xread_with_a_key
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')

      actual = redis.xread('s1', 0)

      assert_equal %w(v1 v2), actual.fetch('s1').map { |i| i.last['f'] }
    end

    def test_xread_with_multiple_keys
      redis.xadd('s1', { f: 'v01' }, id: '0-1')
      redis.xadd('s1', { f: 'v02' }, id: '0-2')
      redis.xadd('s2', { f: 'v11' }, id: '1-1')
      redis.xadd('s2', { f: 'v12' }, id: '1-2')

      actual = redis.xread(%w[s1 s2], %w[0-1 1-1])

      assert_equal 1, actual['s1'].size
      assert_equal 1, actual['s2'].size
      assert_equal 'v02', actual['s1'][0].last['f']
      assert_equal 'v12', actual['s2'][0].last['f']
    end

    def test_xread_with_count_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')

      actual = redis.xread('s1', 0, count: 1)

      assert_equal 1, actual['s1'].size
    end

    def test_xread_with_block_option
      actual = redis.xread('s1', '$', block: LOW_TIMEOUT * 1000)
      assert_equal({}, actual)
    end

    def test_xread_does_not_raise_timeout_error_when_the_block_option_is_zero_msec
      prepared = false
      actual = nil
      wire = Wire.new do
        prepared = true
        actual = redis.xread('s1', 0, block: 0)
      end
      Wire.pass until prepared
      redis.dup.xadd('s1', { f: 'v1' }, id: '0-1')
      wire.join

      assert_equal ['v1'], actual.fetch('s1').map { |i| i.last['f'] }
    end

    def test_xread_with_invalid_arguments
      assert_raises(Redis::CommandError) { redis.xread(nil, nil) }
      assert_raises(Redis::CommandError) { redis.xread('', '') }
      assert_raises(Redis::CommandError) { redis.xread([], []) }
      assert_raises(Redis::CommandError) { redis.xread([''], ['']) }
      assert_raises(Redis::CommandError) { redis.xread('s1', '0-0', count: 'a') }
      assert_raises(Redis::CommandError) { redis.xread('s1', %w[0-0 0-0]) }
    end

    def test_xgroup_with_create_subcommand
      redis.xadd('s1', f: 'v')
      assert_equal 'OK', redis.xgroup(:create, 's1', 'g1', '$')
    end

    def test_xgroup_with_create_subcommand_and_mkstream_option
      err_msg = 'ERR The XGROUP subcommand requires the key to exist. '\
        'Note that for CREATE you may want to use the MKSTREAM option to create an empty stream automatically.'
      assert_raises(Redis::CommandError, err_msg) { redis.xgroup(:create, 's2', 'g1', '$') }
      assert_equal 'OK', redis.xgroup(:create, 's2', 'g1', '$', mkstream: true)
    end

    def test_xgroup_with_create_subcommand_and_existed_stream_key
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')
      assert_raises(Redis::CommandError, 'BUSYGROUP Consumer Group name already exists') do
        redis.xgroup(:create, 's1', 'g1', '$')
      end
    end

    def test_xgroup_with_setid_subcommand
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')
      assert_equal 'OK', redis.xgroup(:setid, 's1', 'g1', '0')
    end

    def test_xgroup_with_destroy_subcommand
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')
      assert_equal 1, redis.xgroup(:destroy, 's1', 'g1')
    end

    def test_xgroup_with_delconsumer_subcommand
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')
      assert_equal 0, redis.xgroup(:delconsumer, 's1', 'g1', 'c1')
    end

    def test_xgroup_with_invalid_arguments
      assert_raises(Redis::CommandError) { redis.xgroup(nil, nil, nil) }
      assert_raises(Redis::CommandError) { redis.xgroup('', '', '') }
    end

    def test_xreadgroup_with_a_key
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')

      actual = redis.xreadgroup('g1', 'c1', 's1', '>')

      assert_equal 2, actual['s1'].size
      assert_equal 'v2', actual['s1'][0].last['f']
      assert_equal 'v3', actual['s1'][1].last['f']
    end

    def test_xreadgroup_with_multiple_keys
      redis.xadd('s1', { f: 'v01' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s2', { f: 'v11' }, id: '1-1')
      redis.xgroup(:create, 's2', 'g1', '$')
      redis.xadd('s1', { f: 'v02' }, id: '0-2')
      redis.xadd('s2', { f: 'v12' }, id: '1-2')

      actual = redis.xreadgroup('g1', 'c1', %w[s1 s2], %w[> >])

      assert_equal 1, actual['s1'].size
      assert_equal 1, actual['s2'].size
      assert_equal 'v02', actual['s1'][0].last['f']
      assert_equal 'v12', actual['s2'][0].last['f']
    end

    def test_xreadgroup_with_count_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')

      actual = redis.xreadgroup('g1', 'c1', 's1', '>', count: 1)

      assert_equal 1, actual['s1'].size
    end

    def test_xreadgroup_with_noack_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')

      actual = redis.xreadgroup('g1', 'c1', 's1', '>', noack: true)

      assert_equal 2, actual['s1'].size
    end

    def test_xreadgroup_with_block_option
      redis.xadd('s1', f: 'v')
      redis.xgroup(:create, 's1', 'g1', '$')

      actual = redis.xreadgroup('g1', 'c1', 's1', '>', block: LOW_TIMEOUT * 1000)

      assert_equal({}, actual)
    end

    def test_xreadgroup_with_invalid_arguments
      assert_raises(Redis::CommandError) { redis.xreadgroup(nil, nil, nil, nil) }
      assert_raises(Redis::CommandError) { redis.xreadgroup('', '', '', '') }
      assert_raises(Redis::CommandError) { redis.xreadgroup('', '', [], []) }
      assert_raises(Redis::CommandError) { redis.xreadgroup('', '', [''], ['']) }
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      assert_raises(Redis::CommandError) { redis.xreadgroup('g1', 'c1', 's1', '>', count: 'a') }
      assert_raises(Redis::CommandError) { redis.xreadgroup('g1', 'c1', 's1', %w[> >]) }
    end

    def test_xack_with_a_entry_id
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      assert_equal 1, redis.xack('s1', 'g1', '0-2')
    end

    def test_xack_with_splatted_entry_ids
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      redis.xadd('s1', { f: 'v4' }, id: '0-4')
      redis.xadd('s1', { f: 'v5' }, id: '0-5')
      assert_equal 2, redis.xack('s1', 'g1', '0-2', '0-3')
    end

    def test_xack_with_arrayed_entry_ids
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      redis.xadd('s1', { f: 'v4' }, id: '0-4')
      redis.xadd('s1', { f: 'v5' }, id: '0-5')
      assert_equal 2, redis.xack('s1', 'g1', %w[0-2 0-3])
    end

    def test_xack_with_invalid_arguments
      assert_equal 0, redis.xack(nil, nil, nil)
      assert_equal 0, redis.xack('', '', '')
      assert_raises(Redis::CommandError) { redis.xack('', '', []) }
      assert_equal 0, redis.xack('', '', [''])
    end

    def test_xclaim_with_splatted_entry_ids
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, '0-2', '0-3')

      assert_equal %w(0-2 0-3), actual.map(&:first)
      assert_equal %w(v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xclaim_with_arrayed_entry_ids
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, %w[0-2 0-3])

      assert_equal %w(0-2 0-3), actual.map(&:first)
      assert_equal %w(v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xclaim_with_idle_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, '0-2', '0-3', idle: 0)

      assert_equal %w(0-2 0-3), actual.map(&:first)
      assert_equal %w(v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xclaim_with_time_option
      time = Time.now.strftime('%s%L')
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, '0-2', '0-3', time: time)

      assert_equal %w(0-2 0-3), actual.map(&:first)
      assert_equal %w(v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xclaim_with_retrycount_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, '0-2', '0-3', retrycount: 10)

      assert_equal %w(0-2 0-3), actual.map(&:first)
      assert_equal %w(v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xclaim_with_force_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, '0-2', '0-3', force: true)

      assert_equal %w(0-2 0-3), actual.map(&:first)
      assert_equal %w(v2 v3), actual.map { |i| i.last['f'] }
    end

    def test_xclaim_with_justid_option
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      sleep 0.01

      actual = redis.xclaim('s1', 'g1', 'c2', 10, '0-2', '0-3', justid: true)

      assert_equal 2, actual.size
      assert_equal '0-2', actual[0]
      assert_equal '0-3', actual[1]
    end

    def test_xclaim_with_invalid_arguments
      assert_raises(Redis::CommandError) { redis.xclaim(nil, nil, nil, nil, nil) }
      assert_raises(Redis::CommandError) { redis.xclaim('', '', '', '', '') }
    end

    def test_xpending
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')

      actual = redis.xpending('s1', 'g1')

      assert_equal 2, actual['size']
      assert_equal '0-2', actual['min_entry_id']
      assert_equal '0-3', actual['max_entry_id']
      assert_equal '2', actual['consumers']['c1']
    end

    def test_xpending_with_range_options
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      redis.xadd('s1', { f: 'v4' }, id: '0-4')
      redis.xreadgroup('g1', 'c2', 's1', '>')

      actual = redis.xpending('s1', 'g1', '-', '+', 10)

      assert_equal 3, actual.size
      assert_equal '0-2', actual[0]['entry_id']
      assert_equal 'c1', actual[0]['consumer']
      assert_equal true, actual[0]['elapsed'] >= 0
      assert_equal 1, actual[0]['count']
      assert_equal '0-3', actual[1]['entry_id']
      assert_equal 'c1', actual[1]['consumer']
      assert_equal true, actual[1]['elapsed'] >= 0
      assert_equal 1, actual[1]['count']
      assert_equal '0-4', actual[2]['entry_id']
      assert_equal 'c2', actual[2]['consumer']
      assert_equal true, actual[2]['elapsed'] >= 0
      assert_equal 1, actual[2]['count']
    end

    def test_xpending_with_range_and_consumer_options
      redis.xadd('s1', { f: 'v1' }, id: '0-1')
      redis.xgroup(:create, 's1', 'g1', '$')
      redis.xadd('s1', { f: 'v2' }, id: '0-2')
      redis.xadd('s1', { f: 'v3' }, id: '0-3')
      redis.xreadgroup('g1', 'c1', 's1', '>')
      redis.xadd('s1', { f: 'v4' }, id: '0-4')
      redis.xreadgroup('g1', 'c2', 's1', '>')

      actual = redis.xpending('s1', 'g1', '-', '+', 10, 'c1')

      assert_equal 2, actual.size
      assert_equal '0-2', actual[0]['entry_id']
      assert_equal 'c1', actual[0]['consumer']
      assert_equal true, actual[0]['elapsed'] >= 0
      assert_equal 1, actual[0]['count']
      assert_equal '0-3', actual[1]['entry_id']
      assert_equal 'c1', actual[1]['consumer']
      assert_equal true, actual[1]['elapsed'] >= 0
      assert_equal 1, actual[1]['count']
    end
  end
end
