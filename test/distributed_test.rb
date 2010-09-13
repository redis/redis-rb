require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

require "redis/distributed"

class RedisDistributedTest < Test::Unit::TestCase
  NODES = ["redis://127.0.0.1:6379/15"]

  setup do
    @log = StringIO.new
    @r = prepare Redis::Distributed.new(NODES, :logger => ::Logger.new(@log))
  end

  context "Internals" do
    test "Logger" do
      @r.ping

      assert_match(/Redis >> PING/, @log.string)
    end

    test "Recovers from failed commands" do
      # See http://github.com/ezmobius/redis-rb/issues#issue/28

      assert_raises ArgumentError do
        @r.srem "foo"
      end

      assert_nothing_raised do
        @r.info
      end
    end
  end

  context "Connection handling" do
    test "PING" do
      assert_equal ["PONG"], @r.ping
    end

    test "SELECT" do
      @r.set "foo", "bar"

      @r.select 14
      assert_equal nil, @r.get("foo")

      @r.select 15

      assert_equal "bar", @r.get("foo")
    end
  end

  context "Commands operating on all the kind of values" do
    test "EXISTS" do
      assert_equal false, @r.exists("foo")

      @r.set("foo", "s1")

      assert_equal true,  @r.exists("foo")
    end

    test "DEL" do
      @r.set "foo", "s1"
      @r.set "bar", "s2"
      @r.set "baz", "s3"

      assert_equal ["bar", "baz", "foo"], @r.keys("*").sort

      assert_equal [1], @r.del("foo")

      assert_equal ["bar", "baz"], @r.keys("*").sort

      assert_equal [2], @r.del("bar", "baz")

      assert_equal [], @r.keys("*").sort
    end

    test "TYPE" do
      assert_equal "none", @r.type("foo")

      @r.set("foo", "s1")

      assert_equal "string", @r.type("foo")
    end

    test "KEYS" do
      @r.set("f", "s1")
      @r.set("fo", "s2")
      @r.set("foo", "s3")

      assert_equal ["f","fo", "foo"], @r.keys("f*").sort
    end

    test "RANDOMKEY" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.randomkey
      end
    end

    test "RENAME" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.set("foo", "s1")
        @r.rename "foo", "bar"
      end

      assert_equal "s1", @r.get("foo")
      assert_equal nil, @r.get("bar")
    end

    test "RENAMENX" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.set("foo", "s1")
        @r.rename "foo", "bar"
      end

      assert_equal "s1", @r.get("foo")
      assert_equal nil, @r.get("bar")
    end

    test "DBSIZE" do
      assert_equal [0], @r.dbsize

      @r.set("foo", "s1")

      assert_equal [1], @r.dbsize
    end

    test "EXPIRE" do
      @r.set("foo", "s1")
      @r.expire("foo", 1)

      assert_equal "s1", @r.get("foo")

      sleep 2

      assert_equal nil, @r.get("foo")
    end

    test "EXPIREAT" do
      @r.set("foo", "s1")
      @r.expireat("foo", Time.now.to_i + 1)

      assert_equal "s1", @r.get("foo")

      sleep 2

      assert_equal nil, @r.get("foo")
    end

    test "PERSIST" do
      @r.set("foo", "s1")
      @r.expire("foo", 1)
      @r.persist("foo")

      assert_equal(-1, @r.ttl("foo"))
    end

    test "TTL" do
      @r.set("foo", "s1")
      @r.expire("foo", 1)

      assert_equal 1, @r.ttl("foo")
    end

    test "MOVE" do
      @r.select 14
      @r.flushdb

      @r.set "bar", "s3"

      @r.select 15

      @r.set "foo", "s1"
      @r.set "bar", "s2"

      assert @r.move("foo", 14)
      assert_nil @r.get("foo")

      assert !@r.move("bar", 14)
      assert_equal "s2", @r.get("bar")

      @r.select 14

      assert_equal "s1", @r.get("foo")
      assert_equal "s3", @r.get("bar")
    end

    test "FLUSHDB" do
      @r.set("foo", "s1")
      @r.set("bar", "s2")

      assert_equal [2], @r.dbsize

      @r.flushdb

      assert_equal [0], @r.dbsize
    end
  end

  context "Commands requiring clustering" do
    test "RENAME" do
      @r.set("{qux}foo", "s1")
      @r.rename "{qux}foo", "{qux}bar"

      assert_equal "s1", @r.get("{qux}bar")
      assert_equal nil, @r.get("{qux}foo")
    end

    test "RENAMENX" do
      @r.set("{qux}foo", "s1")
      @r.set("{qux}bar", "s2")

      assert_equal false, @r.renamenx("{qux}foo", "{qux}bar")

      assert_equal "s1", @r.get("{qux}foo")
      assert_equal "s2", @r.get("{qux}bar")
    end

    test "RPOPLPUSH" do
      @r.rpush "{qux}foo", "s1"
      @r.rpush "{qux}foo", "s2"

      assert_equal "s2", @r.rpoplpush("{qux}foo", "{qux}bar")
      assert_equal ["s2"], @r.lrange("{qux}bar", 0, -1)
      assert_equal "s1", @r.rpoplpush("{qux}foo", "{qux}bar")
      assert_equal ["s1", "s2"], @r.lrange("{qux}bar", 0, -1)
    end

    test "SMOVE" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}bar", "s2"

      assert @r.smove("{qux}foo", "{qux}bar", "s1")
      assert @r.sismember("{qux}bar", "s1")
    end

    test "SINTER" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}foo", "s2"
      @r.sadd "{qux}bar", "s2"

      assert_equal ["s2"], @r.sinter("{qux}foo", "{qux}bar")
    end

    test "SINTERSTORE" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}foo", "s2"
      @r.sadd "{qux}bar", "s2"

      @r.sinterstore("{qux}baz", "{qux}foo", "{qux}bar")

      assert_equal ["s2"], @r.smembers("{qux}baz")
    end

    test "SUNION" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}foo", "s2"
      @r.sadd "{qux}bar", "s2"
      @r.sadd "{qux}bar", "s3"

      assert_equal ["s1", "s2", "s3"], @r.sunion("{qux}foo", "{qux}bar").sort
    end

    test "SUNIONSTORE" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}foo", "s2"
      @r.sadd "{qux}bar", "s2"
      @r.sadd "{qux}bar", "s3"

      @r.sunionstore("{qux}baz", "{qux}foo", "{qux}bar")

      assert_equal ["s1", "s2", "s3"], @r.smembers("{qux}baz").sort
    end

    test "SDIFF" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}foo", "s2"
      @r.sadd "{qux}bar", "s2"
      @r.sadd "{qux}bar", "s3"

      assert_equal ["s1"], @r.sdiff("{qux}foo", "{qux}bar")
      assert_equal ["s3"], @r.sdiff("{qux}bar", "{qux}foo")
    end

    test "SDIFFSTORE" do
      @r.sadd "{qux}foo", "s1"
      @r.sadd "{qux}foo", "s2"
      @r.sadd "{qux}bar", "s2"
      @r.sadd "{qux}bar", "s3"

      @r.sdiffstore("{qux}baz", "{qux}foo", "{qux}bar")

      assert_equal ["s1"], @r.smembers("{qux}baz")
    end

    test "SORT" do
      @r.set("{qux}foo:1", "s1")
      @r.set("{qux}foo:2", "s2")

      @r.rpush("{qux}bar", "1")
      @r.rpush("{qux}bar", "2")

      assert_equal ["s1"], @r.sort("{qux}bar", :get => "{qux}foo:*", :limit => [0, 1])
      assert_equal ["s2"], @r.sort("{qux}bar", :get => "{qux}foo:*", :limit => [0, 1], :order => "desc alpha")
    end

    test "SORT with an array of GETs" do
      @r.set("{qux}foo:1:a", "s1a")
      @r.set("{qux}foo:1:b", "s1b")

      @r.set("{qux}foo:2:a", "s2a")
      @r.set("{qux}foo:2:b", "s2b")

      @r.rpush("{qux}bar", "1")
      @r.rpush("{qux}bar", "2")

      assert_equal ["s1a", "s1b"], @r.sort("{qux}bar", :get => ["{qux}foo:*:a", "{qux}foo:*:b"], :limit => [0, 1])
      assert_equal ["s2a", "s2b"], @r.sort("{qux}bar", :get => ["{qux}foo:*:a", "{qux}foo:*:b"], :limit => [0, 1], :order => "desc alpha")
    end

    test "SORT with STORE" do
      @r.set("{qux}foo:1", "s1")
      @r.set("{qux}foo:2", "s2")

      @r.rpush("{qux}bar", "1")
      @r.rpush("{qux}bar", "2")

      @r.sort("{qux}bar", :get => "{qux}foo:*", :store => "{qux}baz")
      assert_equal ["s1", "s2"], @r.lrange("{qux}baz", 0, -1)
    end
  end

  context "Commands operating on string values" do
    test "SET and GET" do
      @r.set("foo", "s1")

      assert_equal "s1", @r.get("foo")
    end

    test "SET and GET with brackets" do
      @r["foo"] = "s1"

      assert_equal "s1", @r["foo"]
    end

    test "SET and GET with newline characters" do
      @r.set("foo", "1\n")

      assert_equal "1\n", @r.get("foo")
    end

    test "SET and GET with ASCII characters" do
      with_external_encoding("ASCII-8BIT") do
        (0..255).each do |i|
          str = "#{i.chr}---#{i.chr}"
          @r.set("foo", str)

          assert_equal str, @r.get("foo")
        end
      end
    end if defined?(Encoding)

    test "SETEX" do
      @r.setex("foo", 1, "s1")

      assert_equal "s1", @r.get("foo")

      sleep 2

      assert_equal nil, @r.get("foo")
    end

    test "GETSET" do
      @r.set("foo", "bar")

      assert_equal "bar", @r.getset("foo", "baz")
      assert_equal "baz", @r.get("foo")
    end

    test "MGET" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.mget("foo", "bar")
      end
    end

    test "MGET mapped" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.mapped_mget("foo", "bar")
      end
    end

    test "SETNX" do
      @r.set("foo", "s1")

      assert_equal "s1", @r.get("foo")

      @r.setnx("foo", "s2")

      assert_equal "s1", @r.get("foo")
    end

    test "MSET" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.mset(:foo, "s1", :bar, "s2")
      end
    end

    test "MSET mapped" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.mapped_mset(:foo => "s1", :bar => "s2")
      end
    end

    test "MSETNX" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.set("foo", "s1")
        @r.msetnx(:foo, "s2", :bar, "s3")
      end
    end

    test "MSETNX mapped" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.set("foo", "s1")
        @r.mapped_msetnx(:foo => "s2", :bar => "s3")
      end
    end

    test "INCR" do
      assert_equal 1, @r.incr("foo")
      assert_equal 2, @r.incr("foo")
      assert_equal 3, @r.incr("foo")
    end

    test "INCRBY" do
      assert_equal 1, @r.incrby("foo", 1)
      assert_equal 3, @r.incrby("foo", 2)
      assert_equal 6, @r.incrby("foo", 3)
    end

    test "DECR" do
      @r.set("foo", 3)

      assert_equal 2, @r.decr("foo")
      assert_equal 1, @r.decr("foo")
      assert_equal 0, @r.decr("foo")
    end

    test "DECRBY" do
      @r.set("foo", 6)

      assert_equal 3, @r.decrby("foo", 3)
      assert_equal 1, @r.decrby("foo", 2)
      assert_equal 0, @r.decrby("foo", 1)
    end

    test "APPEND" do
      @r.set "foo", "s"
      @r.append "foo", "1"

      assert_equal "s1", @r.get("foo")
    end

    test "SUBSTR" do
      @r.set "foo", "lorem"

      assert_equal "ore", @r.substr("foo", 1, 3)
    end
  end

  context "Commands operating on lists" do
    test "RPUSH" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal 2, @r.llen("foo")
      assert_equal "s2", @r.rpop("foo")
    end

    test "LPUSH" do
      @r.lpush "foo", "s1"
      @r.lpush "foo", "s2"

      assert_equal 2, @r.llen("foo")
      assert_equal "s2", @r.lpop("foo")
    end

    test "LLEN" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal 2, @r.llen("foo")
    end

    test "LRANGE" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"
      @r.rpush "foo", "s3"

      assert_equal ["s2", "s3"], @r.lrange("foo", 1, -1)
      assert_equal ["s1", "s2"], @r.lrange("foo", 0, 1)
    end

    test "LTRIM" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"
      @r.rpush "foo", "s3"

      @r.ltrim "foo", 0, 1

      assert_equal 2, @r.llen("foo")
      assert_equal ["s1", "s2"], @r.lrange("foo", 0, -1)
    end

    test "LINDEX" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal "s1", @r.lindex("foo", 0)
      assert_equal "s2", @r.lindex("foo", 1)
    end

    test "LSET" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal "s2", @r.lindex("foo", 1)
      assert @r.lset("foo", 1, "s3")
      assert_equal "s3", @r.lindex("foo", 1)

      assert_raises RuntimeError do
        @r.lset("foo", 4, "s3")
      end
    end

    test "LREM" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal 1, @r.lrem("foo", 1, "s1")
      assert_equal ["s2"], @r.lrange("foo", 0, -1)
    end

    test "LPOP" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal 2, @r.llen("foo")
      assert_equal "s1", @r.lpop("foo")
      assert_equal 1, @r.llen("foo")
    end

    test "RPOP" do
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal 2, @r.llen("foo")
      assert_equal "s2", @r.rpop("foo")
      assert_equal 1, @r.llen("foo")
    end

    test "RPOPLPUSH" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.rpoplpush("foo", "bar")
      end
    end
  end

  context "Blocking commands" do
    test "BLPOP" do
      @r.lpush("foo", "s1")
      @r.lpush("foo", "s2")

      thread = Thread.new do
        redis = Redis::Distributed.new(NODES)
        sleep 0.3
        redis.lpush("foo", "s3")
      end

      assert_equal ["foo", "s2"], @r.blpop("foo", 1)
      assert_equal ["foo", "s1"], @r.blpop("foo", 1)
      assert_equal ["foo", "s3"], @r.blpop("foo", 1)

      thread.join
    end

    test "BRPOP" do
      @r.rpush("foo", "s1")
      @r.rpush("foo", "s2")

      t = Thread.new do
        redis = Redis::Distributed.new(NODES)
        sleep 0.3
        redis.rpush("foo", "s3")
      end

      assert_equal ["foo", "s2"], @r.brpop("foo", 1)
      assert_equal ["foo", "s1"], @r.brpop("foo", 1)
      assert_equal ["foo", "s3"], @r.brpop("foo", 1)

      t.join
    end

    test "BRPOP should unset a configured socket timeout" do
      @r = Redis::Distributed.new(NODES, :timeout => 1)

      assert_nothing_raised do
        @r.brpop("foo", 2)
      end # Errno::EAGAIN raised if socket times out before redis command times out

      assert @r.nodes.all? { |node| node.client.timeout == 1 }
    end
  end

  context "Commands operating on sets" do
    test "SADD" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"

      assert_equal ["s1", "s2"], @r.smembers("foo").sort
    end

    test "SREM" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"

      @r.srem("foo", "s1")

      assert_equal ["s2"], @r.smembers("foo")
    end

    test "SPOP" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"

      assert ["s1", "s2"].include?(@r.spop("foo"))
      assert ["s1", "s2"].include?(@r.spop("foo"))
      assert_nil @r.spop("foo")
    end

    test "SMOVE" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "bar", "s2"

        @r.smove("foo", "bar", "s1")
      end
    end

    test "SCARD" do
      assert_equal 0, @r.scard("foo")

      @r.sadd "foo", "s1"

      assert_equal 1, @r.scard("foo")

      @r.sadd "foo", "s2"

      assert_equal 2, @r.scard("foo")
    end

    test "SISMEMBER" do
      assert_equal false, @r.sismember("foo", "s1")

      @r.sadd "foo", "s1"

      assert_equal true,  @r.sismember("foo", "s1")
      assert_equal false, @r.sismember("foo", "s2")
    end

    test "SINTER" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "foo", "s2"
        @r.sadd "bar", "s2"

        @r.sinter("foo", "bar")
      end
    end

    test "SINTERSTORE" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "foo", "s2"
        @r.sadd "bar", "s2"

        @r.sinterstore("baz", "foo", "bar")
      end
    end

    test "SUNION" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "foo", "s2"
        @r.sadd "bar", "s2"
        @r.sadd "bar", "s3"

        @r.sunion("foo", "bar")
      end
    end

    test "SUNIONSTORE" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "foo", "s2"
        @r.sadd "bar", "s2"
        @r.sadd "bar", "s3"

        @r.sunionstore("baz", "foo", "bar")
      end
    end

    test "SDIFF" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "foo", "s2"
        @r.sadd "bar", "s2"
        @r.sadd "bar", "s3"

        @r.sdiff("foo", "bar")
      end
    end

    test "SDIFFSTORE" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.sadd "foo", "s1"
        @r.sadd "foo", "s2"
        @r.sadd "bar", "s2"
        @r.sadd "bar", "s3"

        @r.sdiffstore("baz", "foo", "bar")
      end
    end

    test "SMEMBERS" do
      assert_equal [], @r.smembers("foo")

      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"

      assert_equal ["s1", "s2"], @r.smembers("foo").sort
    end

    test "SRANDMEMBER" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"

      4.times do
        assert ["s1", "s2"].include?(@r.srandmember("foo"))
      end

      assert_equal 2, @r.scard("foo")
    end
  end

  context "Commands operating on sorted sets" do
    test "ZADD" do
      assert_equal 0, @r.zcard("foo")

      @r.zadd "foo", 1, "s1"

      assert_equal 1, @r.zcard("foo")
    end

    test "ZREM" do
      @r.zadd "foo", 1, "s1"

      assert_equal 1, @r.zcard("foo")

      @r.zadd "foo", 2, "s2"

      assert_equal 2, @r.zcard("foo")

      @r.zrem "foo", "s1"

      assert_equal 1, @r.zcard("foo")
    end

    test "ZINCRBY" do
      @r.zincrby "foo", 1, "s1"

      assert_equal "1", @r.zscore("foo", "s1")

      @r.zincrby "foo", 10, "s1"

      assert_equal "11", @r.zscore("foo", "s1")
    end

    test "ZRANK" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"

      assert_equal 2, @r.zrank("foo", "s3")
    end

    test "ZREVRANK" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"

      assert_equal 0, @r.zrevrank("foo", "s3")
    end

    test "ZRANGE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"

      assert_equal ["s1", "s2"], @r.zrange("foo", 0, 1)
      assert_equal ["s1", "1", "s2", "2"], @r.zrange("foo", 0, 1, :with_scores => true)
    end

    test "ZREVRANGE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"

      assert_equal ["s3", "s2"], @r.zrevrange("foo", 0, 1)
      assert_equal ["s3", "3", "s2", "2"], @r.zrevrange("foo", 0, 1, :with_scores => true)
    end

    test "ZRANGEBYSCORE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"

      assert_equal ["s2", "s3"], @r.zrangebyscore("foo", 2, 3)
    end

    test "ZRANGEBYSCORE with LIMIT" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "foo", 4, "s4"

      assert_equal ["s2"], @r.zrangebyscore("foo", 2, 4, :limit => [0, 1])
      assert_equal ["s3"], @r.zrangebyscore("foo", 2, 4, :limit => [1, 1])
      assert_equal ["s3", "s4"], @r.zrangebyscore("foo", 2, 4, :limit => [1, 2])
    end

    test "ZRANGEBYSCORE with WITHSCORES" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "foo", 4, "s4"

      assert_equal ["s2", "2"], @r.zrangebyscore("foo", 2, 4, :limit => [0, 1], :with_scores => true)
      assert_equal ["s3", "3"], @r.zrangebyscore("foo", 2, 4, :limit => [1, 1], :with_scores => true)
    end

    test "ZCARD" do
      assert_equal 0, @r.zcard("foo")

      @r.zadd "foo", 1, "s1"

      assert_equal 1, @r.zcard("foo")
    end

    test "ZSCORE" do
      @r.zadd "foo", 1, "s1"

      assert_equal "1", @r.zscore("foo", "s1")

      assert_nil @r.zscore("foo", "s2")
      assert_nil @r.zscore("bar", "s1")
    end

    test "ZREMRANGEBYRANK" do
      @r.zadd "foo", 10, "s1"
      @r.zadd "foo", 20, "s2"
      @r.zadd "foo", 30, "s3"
      @r.zadd "foo", 40, "s4"

      assert_equal 3, @r.zremrangebyrank("foo", 1, 3)
      assert_equal ["s1"], @r.zrange("foo", 0, 4)
    end

    test "ZREMRANGEBYSCORE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "foo", 4, "s4"

      assert_equal 3, @r.zremrangebyscore("foo", 2, 4)
      assert_equal ["s1"], @r.zrange("foo", 0, 4)
    end

    test "ZUNION" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.zunionstore("foobar", ["foo", "bar"])
      end

      assert_raises Redis::Distributed::CannotDistribute do
        @r.zunionstore("{qux}foobar", ["foo", "bar"])
      end

      assert_raises Redis::Distributed::CannotDistribute do
        @r.zunionstore("{qux}foobar", ["{qux}foo", "bar"])
      end
    end

    test "ZUNION with tags" do
      @r.zadd "{qux}foo", 1, "s1"
      @r.zadd "{qux}bar", 2, "s2"
      @r.zadd "{qux}foo", 3, "s3"
      @r.zadd "{qux}bar", 4, "s4"

      assert_equal 4, @r.zunionstore("{qux}foobar", ["{qux}foo", "{qux}bar"])
    end

    test "ZUNIONSTORE with WEIGHTS" do
      @r.zadd "{qux}foo", 1, "s1"
      @r.zadd "{qux}foo", 3, "s3"
      @r.zadd "{qux}bar", 20, "s2"
      @r.zadd "{qux}bar", 40, "s4"

      assert_equal 4, @r.zunionstore("{qux}foobar", ["{qux}foo", "{qux}bar"])
      assert_equal ["s1", "s3", "s2", "s4"], @r.zrange("{qux}foobar", 0, -1)

      assert_equal 4, @r.zunionstore("{qux}foobar", ["{qux}foo", "{qux}bar"], :weights => [10, 1])
      assert_equal ["s1", "s2", "s3", "s4"], @r.zrange("{qux}foobar", 0, -1)
    end

    test "ZUNION with AGGREGATE" do
      @r.zadd "{qux}foo", 1, "s1"
      @r.zadd "{qux}foo", 2, "s2"
      @r.zadd "{qux}bar", 4, "s2"
      @r.zadd "{qux}bar", 3, "s3"

      assert_equal 3, @r.zunionstore("{qux}foobar", ["{qux}foo", "{qux}bar"])
      assert_equal ["s1", "s3", "s2"], @r.zrange("{qux}foobar", 0, -1)

      assert_equal 3, @r.zunionstore("{qux}foobar", ["{qux}foo", "{qux}bar"], :aggregate => :min)
      assert_equal ["s1", "s2", "s3"], @r.zrange("{qux}foobar", 0, -1)

      assert_equal 3, @r.zunionstore("{qux}foobar", ["{qux}foo", "{qux}bar"], :aggregate => :max)
      assert_equal ["s1", "s3", "s2"], @r.zrange("{qux}foobar", 0, -1)
    end

    test "ZINTER" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.zinterstore("foobar", ["foo", "bar"])
      end

      assert_raises Redis::Distributed::CannotDistribute do
        @r.zinterstore("{qux}foobar", ["foo", "bar"])
      end

      assert_raises Redis::Distributed::CannotDistribute do
        @r.zinterstore("{qux}foobar", ["{qux}foo", "bar"])
      end
    end

    test "ZINTER with tags" do
      @r.zadd "{qux}foo", 1, "s1"
      @r.zadd "{qux}bar", 2, "s1"
      @r.zadd "{qux}foo", 3, "s3"
      @r.zadd "{qux}bar", 4, "s4"

      assert_equal 1, @r.zinterstore("{qux}foobar", ["{qux}foo", "{qux}bar"])
      assert_equal ["s1"], @r.zrange("{qux}foobar", 0, 2)
    end

    test "ZINTER with WEIGHTS" do
      @r.zadd "{qux}foo", 1, "s1"
      @r.zadd "{qux}foo", 2, "s2"
      @r.zadd "{qux}foo", 3, "s3"
      @r.zadd "{qux}bar", 20, "s2"
      @r.zadd "{qux}bar", 30, "s3"
      @r.zadd "{qux}bar", 40, "s4"

      assert_equal 2, @r.zinterstore("{qux}foobar", ["{qux}foo", "{qux}bar"])
      assert_equal ["s2", "s3"], @r.zrange("{qux}foobar", 0, -1)

      assert_equal 2, @r.zinterstore("{qux}foobar", ["{qux}foo", "{qux}bar"], :weights => [10, 1])
      assert_equal ["s2", "s3"], @r.zrange("{qux}foobar", 0, -1)

      assert_equal "40", @r.zscore("{qux}foobar", "s2")
      assert_equal "60", @r.zscore("{qux}foobar", "s3")
    end

    test "ZINTER with AGGREGATE" do
      @r.zadd "{qux}foo", 1, "s1"
      @r.zadd "{qux}foo", 2, "s2"
      @r.zadd "{qux}foo", 3, "s3"
      @r.zadd "{qux}bar", 20, "s2"
      @r.zadd "{qux}bar", 30, "s3"
      @r.zadd "{qux}bar", 40, "s4"

      assert_equal 2, @r.zinterstore("{qux}foobar", ["{qux}foo", "{qux}bar"])
      assert_equal ["s2", "s3"], @r.zrange("{qux}foobar", 0, -1)
      assert_equal "22", @r.zscore("{qux}foobar", "s2")
      assert_equal "33", @r.zscore("{qux}foobar", "s3")

      assert_equal 2, @r.zinterstore("{qux}foobar", ["{qux}foo", "{qux}bar"], :aggregate => :min)
      assert_equal ["s2", "s3"], @r.zrange("{qux}foobar", 0, -1)
      assert_equal "2", @r.zscore("{qux}foobar", "s2")
      assert_equal "3", @r.zscore("{qux}foobar", "s3")

      assert_equal 2, @r.zinterstore("{qux}foobar", ["{qux}foo", "{qux}bar"], :aggregate => :max)
      assert_equal ["s2", "s3"], @r.zrange("{qux}foobar", 0, -1)
      assert_equal "20", @r.zscore("{qux}foobar", "s2")
      assert_equal "30", @r.zscore("{qux}foobar", "s3")
    end
  end

  context "Commands operating on hashes" do
    test "HSET and HGET" do
      @r.hset("foo", "f1", "s1")

      assert_equal "s1", @r.hget("foo", "f1")
    end

    test "HDEL" do
      @r.hset("foo", "f1", "s1")

      assert_equal "s1", @r.hget("foo", "f1")

      @r.hdel("foo", "f1")

      assert_equal nil, @r.hget("foo", "f1")
    end

    test "HEXISTS" do
      assert_equal false, @r.hexists("foo", "f1")

      @r.hset("foo", "f1", "s1")

      assert @r.hexists("foo", "f1")
    end

    test "HLEN" do
      assert_equal 0, @r.hlen("foo")

      @r.hset("foo", "f1", "s1")

      assert_equal 1, @r.hlen("foo")

      @r.hset("foo", "f2", "s2")

      assert_equal 2, @r.hlen("foo")
    end

    test "HKEYS" do
      assert_equal [], @r.hkeys("foo")

      @r.hset("foo", "f1", "s1")
      @r.hset("foo", "f2", "s2")

      assert_equal ["f1", "f2"], @r.hkeys("foo")
    end

    test "HVALS" do
      assert_equal [], @r.hvals("foo")

      @r.hset("foo", "f1", "s1")
      @r.hset("foo", "f2", "s2")

      assert_equal ["s1", "s2"], @r.hvals("foo")
    end

    test "HGETALL" do
      assert_equal({}, @r.hgetall("foo"))

      @r.hset("foo", "f1", "s1")
      @r.hset("foo", "f2", "s2")

      assert_equal({"f1" => "s1", "f2" => "s2"}, @r.hgetall("foo"))
    end

    test "HMSET" do
      @r.hmset("hash", "foo1", "bar1", "foo2", "bar2")

      assert_equal "bar1", @r.hget("hash", "foo1")
      assert_equal "bar2", @r.hget("hash", "foo2")
    end

    test "HMSET with invalid arguments" do
      assert_raises RuntimeError do
        @r.hmset("hash", "foo1", "bar1", "foo2", "bar2", "foo3")
      end
    end

    test "HINCRBY" do
      @r.hincrby("foo", "f1", 1)

      assert_equal "1", @r.hget("foo", "f1")

      @r.hincrby("foo", "f1", 2)

      assert_equal "3", @r.hget("foo", "f1")

      @r.hincrby("foo", "f1", -1)

      assert_equal "2", @r.hget("foo", "f1")
    end
  end

  context "Sorting" do
    test "SORT" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.set("foo:1", "s1")
        @r.set("foo:2", "s2")

        @r.rpush("bar", "1")
        @r.rpush("bar", "2")

        @r.sort("bar", :get => "foo:*", :limit => [0, 1])
      end
    end
  end

  context "Transactions" do
    test "MULTI/DISCARD" do
      @foo = nil

      assert_raises Redis::Distributed::CannotDistribute do
        @r.multi { @foo = 1 }
      end

      assert_nil @foo

      assert_raises Redis::Distributed::CannotDistribute do
        @r.discard
      end
    end

    test "WATCH/UNWATCH" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.watch("foo")
      end

      assert_raises Redis::Distributed::CannotDistribute do
        @r.unwatch
      end
    end
  end

  context "Publish/Subscribe" do

    test "SUBSCRIBE and UNSUBSCRIBE" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.subscribe("foo", "bar") { }
      end

      assert_raises Redis::Distributed::CannotDistribute do
        @r.subscribe("{qux}foo", "bar") { }
      end
    end

    test "SUBSCRIBE and UNSUBSCRIBE with tags" do
      thread = Thread.new do
        @r.subscribe("foo") do |on|
          on.subscribe do |channel, total|
            @subscribed = true
            @t1 = total
          end

          on.message do |channel, message|
            if message == "s1"
              @r.unsubscribe
              @message = message
            end
          end

          on.unsubscribe do |channel, total|
            @unsubscribed = true
            @t2 = total
          end
        end
      end

      Redis::Distributed.new(NODES).publish("foo", "s1")

      thread.join

      assert @subscribed
      assert_equal 1, @t1
      assert @unsubscribed
      assert_equal 0, @t2
      assert_equal "s1", @message
    end

    test "SUBSCRIBE within SUBSCRIBE" do
      @channels = []

      thread = Thread.new do
        @r.subscribe("foo") do |on|
          on.subscribe do |channel, total|
            @channels << channel

            @r.subscribe("bar") if channel == "foo"
            @r.unsubscribe if channel == "bar"
          end
        end
      end

      Redis::Distributed.new(NODES).publish("foo", "s1")

      thread.join

      assert_equal ["foo", "bar"], @channels
    end

    test "other commands within a SUBSCRIBE" do
      assert_raises RuntimeError do
        @r.subscribe("foo") do |on|
          on.subscribe do |channel, total|
            @r.set("bar", "s2")
          end
        end
      end
    end

    test "SUBSCRIBE without a block" do
      assert_raises LocalJumpError do
        @r.subscribe("foo")
      end
    end
  end

  context "Persistence control commands" do
    test "SAVE and BGSAVE" do
      assert_nothing_raised do
        @r.save
      end

      assert_nothing_raised do
        @r.bgsave
      end
    end

    test "LASTSAVE" do
      assert @r.lastsave.all? { |t| Time.at(t) <= Time.now }
    end
  end

  context "Remote server control commands" do
    test "INFO" do
      %w(last_save_time redis_version total_connections_received connected_clients total_commands_processed connected_slaves uptime_in_seconds used_memory uptime_in_days changes_since_last_save).each do |x|
        @r.info.each do |info|
          assert info.keys.include?(x)
        end
      end
    end

    test "MONITOR" do
      assert_raises NotImplementedError do
        @r.monitor
      end
    end

    test "ECHO" do
      assert_equal ["foo bar baz\n"], @r.echo("foo bar baz\n")
    end
  end

  context "Distributed" do
    test "handle multiple servers" do
      @r = Redis::Distributed.new ["redis://localhost:6379/15", *NODES]

      100.times do |idx|
        @r.set(idx.to_s, "foo#{idx}")
      end

      100.times do |idx|
        assert_equal "foo#{idx}", @r.get(idx.to_s)
      end

      assert_equal "0", @r.keys("*").sort.first
      assert_equal "string", @r.type("1")
    end

    test "add nodes" do
      logger = Logger.new("/dev/null")

      @r = Redis::Distributed.new NODES, :logger => logger, :timeout => 10

      assert_equal "127.0.0.1", @r.nodes[0].client.host
      assert_equal 6379, @r.nodes[0].client.port
      assert_equal 15, @r.nodes[0].client.db
      assert_equal 10, @r.nodes[0].client.timeout
      assert_equal logger, @r.nodes[0].client.logger

      @r.add_node("redis://localhost:6380/14")

      assert_equal "localhost", @r.nodes[1].client.host
      assert_equal 6380, @r.nodes[1].client.port
      assert_equal 14, @r.nodes[1].client.db
      assert_equal 10, @r.nodes[1].client.timeout
      assert_equal logger, @r.nodes[1].client.logger
    end
  end

  context "Pipelining commands" do
    test "cannot be distributed" do
      assert_raises Redis::Distributed::CannotDistribute do
        @r.pipelined do
          @r.lpush "foo", "s1"
          @r.lpush "foo", "s2"
        end
      end
    end
  end

  context "Unknown commands" do
    should "not work by default" do
      assert_raises NoMethodError do
        @r.not_yet_implemented_command
      end
    end
  end

  context "Key tags" do
    should "hash consistently" do
      r1 = Redis::Distributed.new ["redis://localhost:6379/15", *NODES]
      r2 = Redis::Distributed.new ["redis://localhost:6379/15", *NODES]
      r3 = Redis::Distributed.new ["redis://localhost:6379/15", *NODES]

      assert r1.node_for("foo").id == r2.node_for("foo").id
      assert r1.node_for("foo").id == r3.node_for("foo").id
    end

    should "allow clustering of keys" do
      @r = Redis::Distributed.new(NODES)
      @r.add_node("redis://localhost:6379/14")
      @r.flushdb

      100.times do |i|
        @r.set "{foo}users:#{i}", i
      end

      assert_equal [0, 100], @r.nodes.map { |node| node.keys.size }
    end

    should "distribute keys if no clustering is used" do
      @r.add_node("redis://localhost:6379/14")
      @r.flushdb

      @r.set "users:1", 1
      @r.set "users:4", 4

      assert_equal [1, 1], @r.nodes.map { |node| node.keys.size }
    end

    should "allow passing a custom tag extractor" do
      @r = Redis::Distributed.new(NODES, :tag => /^(.+?):/)
      @r.add_node("redis://localhost:6379/14")
      @r.flushdb

      100.times do |i|
        @r.set "foo:users:#{i}", i
      end

      assert_equal [0, 100], @r.nodes.map { |node| node.keys.size }
    end
  end

  teardown do
    @r.nodes.each { |node| node.client.disconnect }
  end
end
