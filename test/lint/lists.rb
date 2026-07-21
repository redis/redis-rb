# frozen_string_literal: true

module Lint
  module Lists
    def test_lmove
      target_version "6.2" do
        r.lpush("foo", "s1")
        r.lpush("foo", "s2") # foo = [s2, s1]
        r.lpush("bar", "s3")
        r.lpush("bar", "s4") # bar = [s4, s3]

        assert_nil r.lmove("nonexistent", "foo", "LEFT", "LEFT")

        assert_equal "s2", r.lmove("foo", "foo", "LEFT", "RIGHT") # foo = [s1, s2]
        assert_equal "s1", r.lmove("foo", "foo", "LEFT", "LEFT") # foo = [s1, s2]

        assert_equal "s1", r.lmove("foo", "bar", "LEFT", "RIGHT") # foo = [s2], bar = [s4, s3, s1]
        assert_equal ["s2"], r.lrange("foo", 0, -1)
        assert_equal ["s4", "s3", "s1"], r.lrange("bar", 0, -1)

        assert_equal "s2", r.lmove("foo", "bar", "LEFT", "LEFT") # foo = [], bar = [s2, s4, s3, s1]
        assert_nil r.lmove("foo", "bar", "LEFT", "LEFT") # foo = [], bar = [s2, s4, s3, s1]
        assert_equal ["s2", "s4", "s3", "s1"], r.lrange("bar", 0, -1)

        error = assert_raises(ArgumentError) do
          r.lmove("foo", "bar", "LEFT", "MIDDLE")
        end
        assert_equal "where_destination must be 'LEFT' or 'RIGHT'", error.message
      end
    end

    def test_lmovem
      target_version "8.9" do
        r.rpush("foo", ["s1", "s2", "s3"])
        r.rpush("bar", ["s4", "s5"])

        assert_nil r.lmovem("nonexistent", "foo", "LEFT", "LEFT")

        # no count/exactly: single element, still an array reply
        assert_equal ["s1"], r.lmovem("foo", "bar", "LEFT", "LEFT") # foo = [s2, s3], bar = [s1, s4, s5]
        assert_equal ["s3"], r.lmovem("foo", "bar", "RIGHT", "RIGHT") # foo = [s2], bar = [s1, s4, s5, s3]
        assert_equal ["s2"], r.lrange("foo", 0, -1)
        assert_equal ["s1", "s4", "s5", "s3"], r.lrange("bar", 0, -1)
      end
    end

    def test_lmovem_count_obo
      target_version "8.9" do
        r.rpush("foo", ["1", "2", "3", "4", "5"])
        r.rpush("bar", ["6", "7", "8", "9", "10"])

        # OBO pushes each element as popped, so the moved block order is reversed
        assert_equal ["3", "2", "1"], r.lmovem("foo", "bar", "LEFT", "LEFT", count: 3, order: "OBO")
        assert_equal ["3", "2", "1", "6", "7", "8", "9", "10"], r.lrange("bar", 0, -1)
        assert_equal ["4", "5"], r.lrange("foo", 0, -1)

        # COUNT moves up to count: fewer when the source holds fewer
        assert_equal ["4", "5"], r.lmovem("foo", "bar", "LEFT", "RIGHT", count: 10, order: "OBO")
        assert_equal ["4", "5"], r.lrange("bar", -2, -1)
        assert_nil r.lmovem("foo", "bar", "LEFT", "LEFT", count: 2, order: "OBO")
      end
    end

    def test_lmovem_count_bulk
      target_version "8.9" do
        r.rpush("foo", ["1", "2", "3", "4", "5"])
        r.rpush("bar", ["6", "7", "8", "9", "10"])

        # BULK preserves the original relative order of the moved elements
        assert_equal ["1", "2", "3"], r.lmovem("foo", "bar", "LEFT", "LEFT", count: 3, order: "BULK")
        assert_equal ["1", "2", "3", "6", "7", "8", "9", "10"], r.lrange("bar", 0, -1)
        assert_equal ["4", "5"], r.lrange("foo", 0, -1)
      end
    end

    def test_lmovem_exactly
      target_version "8.9" do
        r.rpush("foo", ["1", "2", "3"])

        assert_equal ["1", "2"], r.lmovem("foo", "bar", "LEFT", "RIGHT", exactly: 2, order: "BULK")
        assert_equal ["1", "2"], r.lrange("bar", 0, -1)

        # EXACTLY with too few elements moves nothing; source is unchanged
        assert_nil r.lmovem("foo", "bar", "LEFT", "RIGHT", exactly: 2, order: "BULK")
        assert_equal ["3"], r.lrange("foo", 0, -1)
        assert_equal ["1", "2"], r.lrange("bar", 0, -1)
      end
    end

    def test_lmovem_argument_errors
      target_version "8.9" do
        error = assert_raises(ArgumentError) do
          r.lmovem("foo", "bar", "LEFT", "MIDDLE")
        end
        assert_equal "where_destination must be 'LEFT' or 'RIGHT'", error.message

        assert_raises(ArgumentError) do
          r.lmovem("foo", "bar", "LEFT", "RIGHT", count: 1, exactly: 1, order: "BULK")
        end

        # count/exactly require an order, and an order requires count/exactly
        assert_raises(ArgumentError) do
          r.lmovem("foo", "bar", "LEFT", "RIGHT", count: 1)
        end
        assert_raises(ArgumentError) do
          r.lmovem("foo", "bar", "LEFT", "RIGHT", order: "BULK")
        end

        # non-positive count is rejected by the server
        r.rpush("foo", "s1")
        assert_raises(Redis::CommandError) do
          r.lmovem("foo", "bar", "LEFT", "RIGHT", count: 0, order: "BULK")
        end

        # WRONGTYPE when a key holds something else; nothing is moved
        r.set("string", "value")
        assert_raises(Redis::CommandError) do
          r.lmovem("string", "bar", "LEFT", "RIGHT", count: 1, order: "BULK")
        end
        assert_equal ["s1"], r.lrange("foo", 0, -1)
      end
    end

    def test_lpush
      r.lpush "foo", "s1"
      r.lpush "foo", "s2"

      assert_equal 2, r.llen("foo")
      assert_equal "s2", r.lpop("foo")
    end

    def test_variadic_lpush
      assert_equal 3, r.lpush("foo", ["s1", "s2", "s3"])
      assert_equal 3, r.llen("foo")
      assert_equal "s3", r.lpop("foo")
    end

    def test_lpushx
      r.lpushx "foo", "s1"
      r.lpush "foo", "s2"
      r.lpushx "foo", "s3"

      assert_equal 2, r.llen("foo")
      assert_equal ["s3", "s2"], r.lrange("foo", 0, -1)
    end

    def test_rpush
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal 2, r.llen("foo")
      assert_equal "s2", r.rpop("foo")
    end

    def test_variadic_rpush
      assert_equal 3, r.rpush("foo", ["s1", "s2", "s3"])
      assert_equal 3, r.llen("foo")
      assert_equal "s3", r.rpop("foo")
    end

    def test_rpushx
      r.rpushx "foo", "s1"
      r.rpush "foo", "s2"
      r.rpushx "foo", "s3"

      assert_equal 2, r.llen("foo")
      assert_equal ["s2", "s3"], r.lrange("foo", 0, -1)
    end

    def test_llen
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal 2, r.llen("foo")
    end

    def test_lrange
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"
      r.rpush "foo", "s3"

      assert_equal ["s2", "s3"], r.lrange("foo", 1, -1)
      assert_equal ["s1", "s2"], r.lrange("foo", 0, 1)

      assert_equal [], r.lrange("bar", 0, -1)
    end

    def test_ltrim
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"
      r.rpush "foo", "s3"

      r.ltrim "foo", 0, 1

      assert_equal 2, r.llen("foo")
      assert_equal ["s1", "s2"], r.lrange("foo", 0, -1)
    end

    def test_lindex
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal "s1", r.lindex("foo", 0)
      assert_equal "s2", r.lindex("foo", 1)
    end

    def test_lset
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal "s2", r.lindex("foo", 1)
      assert r.lset("foo", 1, "s3")
      assert_equal "s3", r.lindex("foo", 1)

      assert_raises Redis::CommandError do
        r.lset("foo", 4, "s3")
      end
    end

    def test_lrem
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal 1, r.lrem("foo", 1, "s1")
      assert_equal ["s2"], r.lrange("foo", 0, -1)
    end

    def test_lpop
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal 2, r.llen("foo")
      assert_equal "s1", r.lpop("foo")
      assert_equal 1, r.llen("foo")
      assert_nil r.lpop("nonexistent")
    end

    def test_lpop_count
      target_version("6.2") do
        r.rpush "foo", "s1"
        r.rpush "foo", "s2"

        assert_equal 2, r.llen("foo")
        assert_equal ["s1", "s2"], r.lpop("foo", 2)
        assert_equal 0, r.llen("foo")
      end
    end

    def test_rpop
      r.rpush "foo", "s1"
      r.rpush "foo", "s2"

      assert_equal 2, r.llen("foo")
      assert_equal "s2", r.rpop("foo")
      assert_equal 1, r.llen("foo")
      assert_nil r.rpop("nonexistent")
    end

    def test_rpop_count
      target_version("6.2") do
        r.rpush "foo", "s1"
        r.rpush "foo", "s2"

        assert_equal 2, r.llen("foo")
        assert_equal ["s2", "s1"], r.rpop("foo", 2)
        assert_equal 0, r.llen("foo")
      end
    end

    def test_linsert
      r.rpush "foo", "s1"
      r.rpush "foo", "s3"
      r.linsert "foo", :before, "s3", "s2"

      assert_equal ["s1", "s2", "s3"], r.lrange("foo", 0, -1)

      assert_raises(Redis::CommandError) do
        r.linsert "foo", :anywhere, "s3", "s2"
      end
    end

    def test_rpoplpush
      r.rpush 'foo', 's1'
      r.rpush 'foo', 's2'

      assert_equal 's2', r.rpoplpush('foo', 'bar')
      assert_equal ['s2'], r.lrange('bar', 0, -1)
      assert_equal 's1', r.rpoplpush('foo', 'bar')
      assert_equal %w[s1 s2], r.lrange('bar', 0, -1)
    end

    def test_variadic_rpoplpush_expand
      redis.rpush('{1}foo', %w[a b c])
      redis.rpush('{1}bar', %w[d e f])
      assert_equal 'c', redis.rpoplpush('{1}foo', '{1}bar')
    end

    def test_blmpop
      target_version('7.0') do
        assert_nil r.blmpop(0.1, '{1}foo')

        r.lpush('{1}foo', %w[a b c d e f g])
        assert_equal ['{1}foo', ['g']], r.blmpop(0.1, '{1}foo')
        assert_equal ['{1}foo', ['f', 'e']], r.blmpop(0.1, '{1}foo', count: 2)

        r.lpush('{1}foo2', %w[a b])
        assert_equal ['{1}foo', ['a']], r.blmpop(0.1, '{1}foo', '{1}foo2', modifier: "RIGHT")
      end
    end

    def test_lmpop
      target_version('7.0') do
        assert_nil r.lmpop('{1}foo')

        r.lpush('{1}foo', %w[a b c d e f g])
        assert_equal ['{1}foo', ['g']], r.lmpop('{1}foo')
        assert_equal ['{1}foo', ['f', 'e']], r.lmpop('{1}foo', count: 2)

        r.lpush('{1}foo2', %w[a b])
        assert_equal ['{1}foo', ['a']], r.lmpop('{1}foo', '{1}foo2', modifier: "RIGHT")
      end
    end
  end
end
