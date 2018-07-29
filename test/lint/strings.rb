module Lint

  module Strings
    def mock(*args, &block)
      redis_mock(*args, &block)
    end

    def test_set_and_get
      r.set("foo", "s1")

      assert_equal "s1", r.get("foo")
    end

    def test_set_and_get_with_newline_characters
      r.set("foo", "1\n")

      assert_equal "1\n", r.get("foo")
    end

    def test_set_and_get_with_non_string_value
      value = ["a", "b"]

      r.set("foo", value)

      assert_equal value.to_s, r.get("foo")
    end

    def test_set_and_get_with_ascii_characters
      with_external_encoding("ASCII-8BIT") do
        (0..255).each do |i|
          str = "#{i.chr}---#{i.chr}"
          r.set("foo", str)

          assert_equal str, r.get("foo")
        end
      end
    end

    def test_set_with_ex
      target_version "2.6.12" do
        r.set("foo", "bar", :ex => 2)
        assert_in_range 0..2, r.ttl("foo")
      end
    end

    def test_set_with_px
      target_version "2.6.12" do
        r.set("foo", "bar", :px => 2000)
        assert_in_range 0..2, r.ttl("foo")
      end
    end

    def test_set_with_nx
      target_version "2.6.12" do
        r.set("foo", "qux", :nx => true)
        assert !r.set("foo", "bar", :nx => true)
        assert_equal "qux", r.get("foo")

        r.del("foo")
        assert r.set("foo", "bar", :nx => true)
        assert_equal "bar", r.get("foo")
      end
    end

    def test_set_with_xx
      target_version "2.6.12" do
        r.set("foo", "qux")
        assert r.set("foo", "bar", :xx => true)
        assert_equal "bar", r.get("foo")

        r.del("foo")
        assert !r.set("foo", "bar", :xx => true)
      end
    end

    def test_setex
      assert r.setex("foo", 1, "bar")
      assert_equal "bar", r.get("foo")
      assert [0, 1].include? r.ttl("foo")
    end

    def test_setex_with_non_string_value
      value = ["b", "a", "r"]

      assert r.setex("foo", 1, value)
      assert_equal value.to_s, r.get("foo")
      assert [0, 1].include? r.ttl("foo")
    end

    def test_psetex
      target_version "2.5.4" do
        assert r.psetex("foo", 1000, "bar")
        assert_equal "bar", r.get("foo")
        assert [0, 1].include? r.ttl("foo")
      end
    end

    def test_psetex_with_non_string_value
      target_version "2.5.4" do
        value = ["b", "a", "r"]

        assert r.psetex("foo", 1000, value)
        assert_equal value.to_s, r.get("foo")
        assert [0, 1].include? r.ttl("foo")
      end
    end

    def test_getset
      r.set("foo", "bar")

      assert_equal "bar", r.getset("foo", "baz")
      assert_equal "baz", r.get("foo")
    end

    def test_getset_with_non_string_value
      r.set("foo", "zap")

      value = ["b", "a", "r"]

      assert_equal "zap", r.getset("foo", value)
      assert_equal value.to_s, r.get("foo")
    end

    def test_setnx
      r.set("foo", "qux")
      assert !r.setnx("foo", "bar")
      assert_equal "qux", r.get("foo")

      r.del("foo")
      assert r.setnx("foo", "bar")
      assert_equal "bar", r.get("foo")
    end

    def test_setnx_with_non_string_value
      value = ["b", "a", "r"]

      r.set("foo", "qux")
      assert !r.setnx("foo", value)
      assert_equal "qux", r.get("foo")

      r.del("foo")
      assert r.setnx("foo", value)
      assert_equal value.to_s, r.get("foo")
    end

    def test_incr
      assert_equal 1, r.incr("foo")
      assert_equal 2, r.incr("foo")
      assert_equal 3, r.incr("foo")
    end

    def test_incrby
      assert_equal 1, r.incrby("foo", 1)
      assert_equal 3, r.incrby("foo", 2)
      assert_equal 6, r.incrby("foo", 3)
    end

    def test_incrbyfloat
      target_version "2.5.4" do
        assert_equal 1.23, r.incrbyfloat("foo", 1.23)
        assert_equal 2   , r.incrbyfloat("foo", 0.77)
        assert_equal 1.9 , r.incrbyfloat("foo", -0.1)
      end
    end

    def test_decr
      r.set("foo", 3)

      assert_equal 2, r.decr("foo")
      assert_equal 1, r.decr("foo")
      assert_equal 0, r.decr("foo")
    end

    def test_decrby
      r.set("foo", 6)

      assert_equal 3, r.decrby("foo", 3)
      assert_equal 1, r.decrby("foo", 2)
      assert_equal 0, r.decrby("foo", 1)
    end

    def test_append
      r.set "foo", "s"
      r.append "foo", "1"

      assert_equal "s1", r.get("foo")
    end

    def test_getbit
      r.set("foo", "a")

      assert_equal 1, r.getbit("foo", 1)
      assert_equal 1, r.getbit("foo", 2)
      assert_equal 0, r.getbit("foo", 3)
      assert_equal 0, r.getbit("foo", 4)
      assert_equal 0, r.getbit("foo", 5)
      assert_equal 0, r.getbit("foo", 6)
      assert_equal 1, r.getbit("foo", 7)
    end

    def test_setbit
      r.set("foo", "a")

      r.setbit("foo", 6, 1)

      assert_equal "c", r.get("foo")
    end

    def test_bitcount
      target_version "2.5.10" do
        r.set("foo", "abcde")

        assert_equal 10, r.bitcount("foo", 1, 3)
        assert_equal 17, r.bitcount("foo", 0, -1)
      end
    end

    def test_getrange
      r.set("foo", "abcde")

      assert_equal "bcd", r.getrange("foo", 1, 3)
      assert_equal "abcde", r.getrange("foo", 0, -1)
    end

    def test_setrange
      r.set("foo", "abcde")

      r.setrange("foo", 1, "bar")

      assert_equal "abare", r.get("foo")
    end

    def test_setrange_with_non_string_value
      r.set("foo", "abcde")

      value = ["b", "a", "r"]

      r.setrange("foo", 2, value)

      assert_equal "ab#{value.to_s}", r.get("foo")
    end

    def test_strlen
      r.set "foo", "lorem"

      assert_equal 5, r.strlen("foo")
    end

    def test_bitfield
      target_version('3.2.0') do
        mock(bitfield: ->(*_) { "*2\r\n:1\r\n:0\r\n" }) do |redis|
          assert_equal [1, 0], redis.bitfield('foo', 'INCRBY', 'i5', 100, 1, 'GET', 'u4', 0)
        end
      end
    end

    def test_mget
      r.set('{1}foo', 's1')
      r.set('{1}bar', 's2')

      assert_equal %w[s1 s2],         r.mget('{1}foo', '{1}bar')
      assert_equal ['s1', 's2', nil], r.mget('{1}foo', '{1}bar', '{1}baz')
    end

    def test_mget_mapped
      r.set('{1}foo', 's1')
      r.set('{1}bar', 's2')

      response = r.mapped_mget('{1}foo', '{1}bar')

      assert_equal 's1', response['{1}foo']
      assert_equal 's2', response['{1}bar']

      response = r.mapped_mget('{1}foo', '{1}bar', '{1}baz')

      assert_equal 's1', response['{1}foo']
      assert_equal 's2', response['{1}bar']
      assert_equal nil,  response['{1}baz']
    end

    def test_mapped_mget_in_a_pipeline_returns_hash
      r.set('{1}foo', 's1')
      r.set('{1}bar', 's2')

      result = r.pipelined do
        r.mapped_mget('{1}foo', '{1}bar')
      end

      assert_equal({ '{1}foo' => 's1', '{1}bar' => 's2' }, result[0])
    end

    def test_mset
      r.mset('{1}foo', 's1', '{1}bar', 's2')

      assert_equal 's1', r.get('{1}foo')
      assert_equal 's2', r.get('{1}bar')
    end

    def test_mset_mapped
      r.mapped_mset('{1}foo' => 's1', '{1}bar' => 's2')

      assert_equal 's1', r.get('{1}foo')
      assert_equal 's2', r.get('{1}bar')
    end

    def test_msetnx
      r.set('{1}foo', 's1')
      assert_equal false, r.msetnx('{1}foo', 's2', '{1}bar', 's3')
      assert_equal 's1', r.get('{1}foo')
      assert_equal nil, r.get('{1}bar')

      r.del('{1}foo')
      assert_equal true, r.msetnx('{1}foo', 's2', '{1}bar', 's3')
      assert_equal 's2', r.get('{1}foo')
      assert_equal 's3', r.get('{1}bar')
    end

    def test_msetnx_mapped
      r.set('{1}foo', 's1')
      assert_equal false, r.mapped_msetnx('{1}foo' => 's2', '{1}bar' => 's3')
      assert_equal 's1', r.get('{1}foo')
      assert_equal nil, r.get('{1}bar')

      r.del('{1}foo')
      assert_equal true, r.mapped_msetnx('{1}foo' => 's2', '{1}bar' => 's3')
      assert_equal 's2', r.get('{1}foo')
      assert_equal 's3', r.get('{1}bar')
    end

    def test_bitop
      with_external_encoding('UTF-8') do
        target_version '2.5.10' do
          r.set('foo{1}', 'a')
          r.set('bar{1}', 'b')

          r.bitop(:and, 'foo&bar{1}', 'foo{1}', 'bar{1}')
          assert_equal "\x60", r.get('foo&bar{1}')
          r.bitop(:or, 'foo|bar{1}', 'foo{1}', 'bar{1}')
          assert_equal "\x63", r.get('foo|bar{1}')
          r.bitop(:xor, 'foo^bar{1}', 'foo{1}', 'bar{1}')
          assert_equal "\x03", r.get('foo^bar{1}')
          r.bitop(:not, '~foo{1}', 'foo{1}')
          assert_equal "\x9E", r.get('~foo{1}')
        end
      end
    end
  end
end
