# encoding: UTF-8

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require File.expand_path(File.join(File.dirname(__FILE__), "redis_mock"))

class RedisTest < Test::Unit::TestCase

  include RedisMock::Helper

  PORT = 6379
  OPTIONS = {:port => PORT, :db => 15, :timeout => 3}

  setup do
    @r = prepare Redis.new(OPTIONS)
  end

  context "initialize with URL" do
    test "defaults to 127.0.0.1:6379" do
      redis = Redis.connect

      assert_equal "127.0.0.1", redis.client.host
      assert_equal 6379, redis.client.port
      assert_equal 0, redis.client.db
      assert_nil redis.client.password
    end

    test "takes a URL" do
      redis = Redis.connect :url => "redis://:secr3t@foo.com:999/2"

      assert_equal "foo.com", redis.client.host
      assert_equal 999, redis.client.port
      assert_equal 2, redis.client.db
      assert_equal "secr3t", redis.client.password
    end

    test "overrides the URL if another connection option is passed" do
      redis = Redis.connect :url => "redis://:secr3t@foo.com:999/2", :port => 1000

      assert_equal "foo.com", redis.client.host
      assert_equal 1000, redis.client.port
      assert_equal 2, redis.client.db
      assert_equal "secr3t", redis.client.password
    end

    test "does not modify the passed options" do
      options = { :url => "redis://:secr3t@foo.com:999/2" }

      redis = Redis.connect(options)

      assert_equal({ :url => "redis://:secr3t@foo.com:999/2" }, options)
    end

    test "uses REDIS_URL over default if available" do
      ENV["REDIS_URL"] = "redis://:secr3t@foo.com:999/2"

      redis = Redis.connect

      assert_equal "foo.com", redis.client.host
      assert_equal 999, redis.client.port
      assert_equal 2, redis.client.db
      assert_equal "secr3t", redis.client.password

      ENV.delete("REDIS_URL")
    end
  end

  context "Internals" do
    setup do
      @log = StringIO.new
      @r = Redis.new(OPTIONS.merge(:logger => ::Logger.new(@log)))
    end

    test "Logger" do
      @r.ping

      assert_match(/Redis >> PING/, @log.string)
      assert_match(/Redis >> \d+\.\d+ms/, @log.string)
    end

    test "Logger with pipelining" do
      @r.pipelined do
        @r.set "foo", "bar"
        @r.get "foo"
      end

      assert @log.string["SET foo bar"]
      assert @log.string["GET foo"]
    end

    test "Timeout" do
      assert_nothing_raised do
        Redis.new(OPTIONS.merge(:timeout => 0))
      end
    end

    test "Connection timeout" do
      assert_raises(Timeout::Error) do
        Redis.new(OPTIONS.merge(:host => "127.0.0.2", :timeout => 1)).ping
      end
    end

    test "Recovers from failed commands" do
      # See http://github.com/ezmobius/redis-rb/issues#issue/28

      assert_raises(ArgumentError) do
        @r.srem "foo"
      end

      assert_nothing_raised do
        @r.info
      end
    end

    test "provides a meaningful inspect" do
      assert_equal "#<Redis client v#{Redis::VERSION} connected to redis://127.0.0.1:6379/15 (Redis v#{@r.info["redis_version"]})>", @r.inspect
    end
  end

  context "Connection handling" do
    test "AUTH" do
      replies = {
        :auth => lambda { |password| $auth = password; "+OK" },
        :get  => lambda { |key| $auth == "secret" ? "$3\r\nbar" : "$-1" },
      }

      redis_mock(replies) do
        redis = Redis.new(OPTIONS.merge(:port => 6380, :password => "secret"))

        assert_equal "bar", redis.get("foo")
      end
    end

    test "PING" do
      assert_equal "PONG", @r.ping
    end

    test "SELECT" do
      @r.set "foo", "bar"

      @r.select 14
      assert_equal nil, @r.get("foo")

      @r.client.disconnect

      assert_equal nil, @r.get("foo")
    end

    test "QUIT" do
      @r.quit

      assert !@r.client.connected?
    end

    test "SHUTDOWN" do
      redis_mock(:shutdown => lambda { "+SHUTDOWN" }) do
        redis = Redis.new(OPTIONS.merge(:port => 6380))

        assert_equal "SHUTDOWN", redis.shutdown
      end
    end

    test "SLAVEOF" do
      redis_mock(:slaveof => lambda { |host, port| "+SLAVEOF #{host} #{port}" }) do
        redis = Redis.new(OPTIONS.merge(:port => 6380))

        assert_equal "SLAVEOF localhost 6381", redis.slaveof("localhost", 6381)
      end
    end

    test "BGREWRITEAOF" do
      redis_mock(:bgrewriteaof => lambda { "+BGREWRITEAOF" }) do
        redis = Redis.new(OPTIONS.merge(:port => 6380))

        assert_equal "BGREWRITEAOF", redis.bgrewriteaof
      end
    end

    test "CONFIG GET" do
      assert_equal "300", @r.config(:get, "*")["timeout"]

      assert_equal @r.config(:get, "timeout"), "timeout" => "300"
    end

    test "CONFIG SET" do
      begin
        assert_equal "OK", @r.config(:set, "timeout", 200)
        assert_equal "200", @r.config(:get, "*")["timeout"]

        assert_equal "OK", @r.config(:set, "timeout", 100)
        assert_equal "100", @r.config(:get, "*")["timeout"]
      ensure
        @r.config :set, "timeout", 300
      end
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

      assert_equal 1, @r.del("foo")

      assert_equal ["bar", "baz"], @r.keys("*").sort

      assert_equal 2, @r.del("bar", "baz")

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
      assert @r.randomkey.to_s.empty?

      @r.set("foo", "s1")

      assert_equal "foo", @r.randomkey

      @r.set("bar", "s2")

      4.times do
        assert ["foo", "bar"].include?(@r.randomkey)
      end
    end

    test "RENAME" do
      @r.set("foo", "s1")
      @r.rename "foo", "bar"

      assert_equal "s1", @r.get("bar")
      assert_equal nil, @r.get("foo")
    end

    test "RENAMENX" do
      @r.set("foo", "s1")
      @r.set("bar", "s2")

      assert_equal false, @r.renamenx("foo", "bar")

      assert_equal "s1", @r.get("foo")
      assert_equal "s2", @r.get("bar")
    end

    test "DBSIZE" do
      assert_equal 0, @r.dbsize

      @r.set("foo", "s1")

      assert_equal 1, @r.dbsize
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

      assert_equal 2, @r.dbsize

      @r.flushdb

      assert_equal 0, @r.dbsize
    end

    test "FLUSHALL" do
      redis_mock(:flushall => lambda { "+FLUSHALL" }) do
        redis = Redis.new(OPTIONS.merge(:port => 6380))

        assert_equal "FLUSHALL", redis.flushall
      end
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
      @r.set("foo", "s1")
      @r.set("bar", "s2")

      assert_equal ["s1", "s2"],      @r.mget("foo", "bar")
      assert_equal ["s1", "s2", nil], @r.mget("foo", "bar", "baz")
    end

    test "MGET mapped" do
      @r.set("foo", "s1")
      @r.set("bar", "s2")

      response = @r.mapped_mget("foo", "bar")

      assert_equal "s1", response["foo"]
      assert_equal "s2", response["bar"]

      response = @r.mapped_mget("foo", "bar", "baz")

      assert_equal "s1", response["foo"]
      assert_equal "s2", response["bar"]
      assert_equal nil,  response["baz"]
    end

    test "SETNX" do
      @r.set("foo", "s1")

      assert_equal "s1", @r.get("foo")

      @r.setnx("foo", "s2")

      assert_equal "s1", @r.get("foo")
    end

    test "MSET" do
      @r.mset(:foo, "s1", :bar, "s2")

      assert_equal "s1", @r.get("foo")
      assert_equal "s2", @r.get("bar")
    end

    test "MSET mapped" do
      @r.mapped_mset(:foo => "s1", :bar => "s2")

      assert_equal "s1", @r.get("foo")
      assert_equal "s2", @r.get("bar")
    end

    test "MSETNX" do
      @r.set("foo", "s1")
      @r.msetnx(:foo, "s2", :bar, "s3")

      assert_equal "s1", @r.get("foo")
      assert_equal nil, @r.get("bar")
    end

    test "MSETNX mapped" do
      @r.set("foo", "s1")
      @r.mapped_msetnx(:foo => "s2", :bar => "s3")

      assert_equal "s1", @r.get("foo")
      assert_equal nil, @r.get("bar")
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

      assert_equal [], @r.lrange("bar", 0, -1)
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
      @r.rpush "foo", "s1"
      @r.rpush "foo", "s2"

      assert_equal "s2", @r.rpoplpush("foo", "bar")
      assert_equal ["s2"], @r.lrange("bar", 0, -1)
      assert_equal "s1", @r.rpoplpush("foo", "bar")
      assert_equal ["s1", "s2"], @r.lrange("bar", 0, -1)
    end
  end

  context "Blocking commands" do
    test "BLPOP" do
      @r.lpush("foo", "s1")
      @r.lpush("foo", "s2")

      thread = Thread.new do
        redis = Redis.new(OPTIONS)
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
        redis = Redis.new(OPTIONS)
        sleep 0.3
        redis.rpush("foo", "s3")
      end

      assert_equal ["foo", "s2"], @r.brpop("foo", 1)
      assert_equal ["foo", "s1"], @r.brpop("foo", 1)
      assert_equal ["foo", "s3"], @r.brpop("foo", 1)

      t.join
    end

    test "BRPOP should unset a configured socket timeout" do
      @r = Redis.new(OPTIONS.merge(:timeout => 1))

      assert_nothing_raised do
        @r.brpop("foo", 2)
      end # Errno::EAGAIN raised if socket times out before Redis command times out

      assert_equal 1, @r.client.timeout
    end

    test "BLPOP can block on multiple lists" do
      @r.lpush("queue1", "job1")
      @r.lpush("queue2", "job2")

      t = Thread.new do
        redis = Redis.new(OPTIONS)
        sleep 0.3
        redis.lpush("queue3", "job3")
      end

      assert_equal ["queue1", "job1"], @r.blpop("queue1", "queue2", "queue3", 1)
      assert_equal ["queue2", "job2"], @r.blpop("queue1", "queue2", "queue3", 1)
      assert_equal ["queue3", "job3"], @r.blpop("queue1", "queue2", "queue3", 1)

      t.join
    end

    test "BRPOP should restore the timeout even if the command fails" do
      @r.incr "foo"

      assert_raise RuntimeError do
        @r.brpop("foo", 1)
      end

      assert_equal OPTIONS[:timeout], @r.client.timeout
    end

    test "BLPOP losing connection" do
      replies = {
        :blpop => lambda { |*_| Process.kill(9, Process.pid) },
        :ping  => lambda { |*_| "+PONG" },
      }

      redis_mock(replies) do
        redis = Redis.new(OPTIONS.merge(:port => 6380))

        assert_equal "PONG", redis.ping

        assert_raises(Errno::ECONNREFUSED) do
          redis.blpop "foo", 1
        end
      end
    end

    test "BLPOP should try to reconnect when disconnected by Redis" do
      times = 0

      replies = {
        :blpop => lambda do |*_|
          times += 1
          "+OK" if times > 2
        end
      }

      redis_mock(replies) do
        assert_equal "OK", Redis.new(OPTIONS.merge(:port => 6380)).blpop("foo", 0)
      end
    end

    test "BLPOP with a timeout should return nil when hitting the timeout" do
      assert_equal nil, @r.blpop("foo", 1)
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
      @r.sadd "foo", "s1"
      @r.sadd "bar", "s2"

      assert @r.smove("foo", "bar", "s1")
      assert @r.sismember("bar", "s1")
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
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"
      @r.sadd "bar", "s2"

      assert_equal ["s2"], @r.sinter("foo", "bar")
    end

    test "SINTERSTORE" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"
      @r.sadd "bar", "s2"

      @r.sinterstore("baz", "foo", "bar")

      assert_equal ["s2"], @r.smembers("baz")
    end

    test "SUNION" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"
      @r.sadd "bar", "s2"
      @r.sadd "bar", "s3"

      assert_equal ["s1", "s2", "s3"], @r.sunion("foo", "bar").sort
    end

    test "SUNIONSTORE" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"
      @r.sadd "bar", "s2"
      @r.sadd "bar", "s3"

      @r.sunionstore("baz", "foo", "bar")

      assert_equal ["s1", "s2", "s3"], @r.smembers("baz").sort
    end

    test "SDIFF" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"
      @r.sadd "bar", "s2"
      @r.sadd "bar", "s3"

      assert_equal ["s1"], @r.sdiff("foo", "bar")
      assert_equal ["s3"], @r.sdiff("bar", "foo")
    end

    test "SDIFFSTORE" do
      @r.sadd "foo", "s1"
      @r.sadd "foo", "s2"
      @r.sadd "bar", "s2"
      @r.sadd "bar", "s3"

      @r.sdiffstore("baz", "foo", "bar")

      assert_equal ["s1"], @r.smembers("baz")
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

    test "ZCOUNT" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"

      assert_equal 2, @r.zcount("foo", 2, 3)
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
      assert_equal ["s1"], @r.zrange("foo", 0, -1)
    end

    test "ZREMRANGEBYSCORE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "foo", 4, "s4"

      assert_equal 3, @r.zremrangebyscore("foo", 2, 4)
      assert_equal ["s1"], @r.zrange("foo", 0, -1)
    end

    test "ZUNIONSTORE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "bar", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "bar", 4, "s4"

      assert_equal 4, @r.zunionstore("foobar", ["foo", "bar"])
      assert_equal ["s1", "s2", "s3", "s4"], @r.zrange("foobar", 0, -1)
    end

    test "ZUNIONSTORE with WEIGHTS" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 3, "s3"
      @r.zadd "bar", 20, "s2"
      @r.zadd "bar", 40, "s4"

      assert_equal 4, @r.zunionstore("foobar", ["foo", "bar"])
      assert_equal ["s1", "s3", "s2", "s4"], @r.zrange("foobar", 0, -1)

      assert_equal 4, @r.zunionstore("foobar", ["foo", "bar"], :weights => [10, 1])
      assert_equal ["s1", "s2", "s3", "s4"], @r.zrange("foobar", 0, -1)
    end

    test "ZUNIONSTORE with AGGREGATE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "bar", 4, "s2"
      @r.zadd "bar", 3, "s3"

      assert_equal 3, @r.zunionstore("foobar", ["foo", "bar"])
      assert_equal ["s1", "s3", "s2"], @r.zrange("foobar", 0, -1)

      assert_equal 3, @r.zunionstore("foobar", ["foo", "bar"], :aggregate => :min)
      assert_equal ["s1", "s2", "s3"], @r.zrange("foobar", 0, -1)

      assert_equal 3, @r.zunionstore("foobar", ["foo", "bar"], :aggregate => :max)
      assert_equal ["s1", "s3", "s2"], @r.zrange("foobar", 0, -1)
    end

    test "ZINTERSTORE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "bar", 2, "s1"
      @r.zadd "foo", 3, "s3"
      @r.zadd "bar", 4, "s4"

      assert_equal 1, @r.zinterstore("foobar", ["foo", "bar"])
      assert_equal ["s1"], @r.zrange("foobar", 0, -1)
    end

    test "ZINTERSTORE with WEIGHTS" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "bar", 20, "s2"
      @r.zadd "bar", 30, "s3"
      @r.zadd "bar", 40, "s4"

      assert_equal 2, @r.zinterstore("foobar", ["foo", "bar"])
      assert_equal ["s2", "s3"], @r.zrange("foobar", 0, -1)

      assert_equal 2, @r.zinterstore("foobar", ["foo", "bar"], :weights => [10, 1])
      assert_equal ["s2", "s3"], @r.zrange("foobar", 0, -1)

      assert_equal "40", @r.zscore("foobar", "s2")
      assert_equal "60", @r.zscore("foobar", "s3")
    end

    test "ZINTERSTORE with AGGREGATE" do
      @r.zadd "foo", 1, "s1"
      @r.zadd "foo", 2, "s2"
      @r.zadd "foo", 3, "s3"
      @r.zadd "bar", 20, "s2"
      @r.zadd "bar", 30, "s3"
      @r.zadd "bar", 40, "s4"

      assert_equal 2, @r.zinterstore("foobar", ["foo", "bar"])
      assert_equal ["s2", "s3"], @r.zrange("foobar", 0, -1)
      assert_equal "22", @r.zscore("foobar", "s2")
      assert_equal "33", @r.zscore("foobar", "s3")

      assert_equal 2, @r.zinterstore("foobar", ["foo", "bar"], :aggregate => :min)
      assert_equal ["s2", "s3"], @r.zrange("foobar", 0, -1)
      assert_equal "2", @r.zscore("foobar", "s2")
      assert_equal "3", @r.zscore("foobar", "s3")

      assert_equal 2, @r.zinterstore("foobar", ["foo", "bar"], :aggregate => :max)
      assert_equal ["s2", "s3"], @r.zrange("foobar", 0, -1)
      assert_equal "20", @r.zscore("foobar", "s2")
      assert_equal "30", @r.zscore("foobar", "s3")
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

    test "HMGET" do
      @r.hset("foo", "f1", "s1")
      @r.hset("foo", "f2", "s2")
      @r.hset("foo", "f3", "s3")

      assert_equal ["s2", "s3"], @r.hmget("foo", "f2", "f3")
    end

    test "HMGET mapped" do
      @r.hset("foo", "f1", "s1")
      @r.hset("foo", "f2", "s2")
      @r.hset("foo", "f3", "s3")

      assert_equal({"f1" => "s1"}, @r.mapped_hmget("foo", "f1"))
      assert_equal({"f1" => "s1", "f2" => "s2"}, @r.mapped_hmget("foo", "f1", "f2"))
    end

    test "HMSET" do
      @r.hmset("hash", "foo1", "bar1", "foo2", "bar2")

      assert_equal "bar1", @r.hget("hash", "foo1")
      assert_equal "bar2", @r.hget("hash", "foo2")
    end

    test "HMSET with invalid arguments" do
      assert_raise(RuntimeError) do
        @r.hmset("hash", "foo1", "bar1", "foo2", "bar2", "foo3")
      end
    end

    test "Mapped HMSET" do
      @r.mapped_hmset("foo", :f1 => "s1", :f2 => "s2")

      assert_equal "s1", @r.hget("foo", "f1")
      assert_equal "s2", @r.hget("foo", "f2")
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
      @r.set("foo:1", "s1")
      @r.set("foo:2", "s2")

      @r.rpush("bar", "1")
      @r.rpush("bar", "2")

      assert_equal ["s1"], @r.sort("bar", :get => "foo:*", :limit => [0, 1])
      assert_equal ["s2"], @r.sort("bar", :get => "foo:*", :limit => [0, 1], :order => "desc alpha")
    end

    test "SORT with an array of GETs" do
      @r.set("foo:1:a", "s1a")
      @r.set("foo:1:b", "s1b")

      @r.set("foo:2:a", "s2a")
      @r.set("foo:2:b", "s2b")

      @r.rpush("bar", "1")
      @r.rpush("bar", "2")

      assert_equal ["s1a", "s1b"], @r.sort("bar", :get => ["foo:*:a", "foo:*:b"], :limit => [0, 1])
      assert_equal ["s2a", "s2b"], @r.sort("bar", :get => ["foo:*:a", "foo:*:b"], :limit => [0, 1], :order => "desc alpha")
    end

    test "SORT with STORE" do
      @r.set("foo:1", "s1")
      @r.set("foo:2", "s2")

      @r.rpush("bar", "1")
      @r.rpush("bar", "2")

      @r.sort("bar", :get => "foo:*", :store => "baz")
      assert_equal ["s1", "s2"], @r.lrange("baz", 0, -1)
    end
  end

  context "Transactions" do
    test "MULTI/DISCARD" do
      @r.multi

      assert_equal "QUEUED", @r.set("foo", "1")
      assert_equal "QUEUED", @r.get("foo")

      @r.discard

      assert_equal nil, @r.get("foo")
    end

    test "MULTI/EXEC with a block" do
      @r.multi do
        @r.set "foo", "s1"
      end

      assert_equal "s1", @r.get("foo")

      begin
        @r.multi do
          @r.set "bar", "s2"
          raise "Some error"
          @r.set "baz", "s3"
        end
      rescue
      end

      assert_nil @r.get("bar")
      assert_nil @r.get("baz")
    end

    test "MULTI/EXEC with a block operating on a wrong kind of key" do
      begin
        @r.multi do
          @r.set "foo", "s1"
          @r.lpush "foo", "s2"
          @r.get "foo"
        end
      rescue RuntimeError
      end

      assert_equal "s1", @r.get("foo")
    end

    test "MULTI with a block yielding the client" do
      @r.multi do |multi|
        multi.set "foo", "s1"
      end

      assert_equal "s1", @r.get("foo")
    end

    test "WATCH with an unmodified key" do
      @r.watch "foo"
      @r.multi do |multi|
        multi.set "foo", "s1"
      end

      assert_equal "s1", @r.get("foo")
    end

    test "WATCH with a modified key" do
      @r.watch "foo"
      @r.set "foo", "s1"
      res = @r.multi do |multi|
        multi.set "foo", "s2"
      end

      assert_nil res
      assert_equal "s1", @r.get("foo")
    end

    test "UNWATCH with a modified key" do
      @r.watch "foo"
      @r.set "foo", "s1"
      @r.unwatch
      @r.multi do |multi|
        multi.set "foo", "s2"
      end

      assert_equal "s2", @r.get("foo")
    end
  end

  context "Publish/Subscribe" do

    test "SUBSCRIBE and UNSUBSCRIBE" do
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

      Redis.new(OPTIONS).publish("foo", "s1")

      thread.join

      assert @subscribed
      assert_equal 1, @t1
      assert @unsubscribed
      assert_equal 0, @t2
      assert_equal "s1", @message
    end

    test "PSUBSCRIBE and PUNSUBSCRIBE" do
      listening = false

      thread = Thread.new do
        @r.psubscribe("f*") do |on|
          on.psubscribe do |pattern, total|
            @subscribed = true
            @t1 = total
          end

          on.pmessage do |pattern, channel, message|
            if message == "s1"
              @r.punsubscribe
              @message = message
            end
          end

          on.punsubscribe do |pattern, total|
            @unsubscribed = true
            @t2 = total
          end

          listening = true
        end
      end

      while !listening; end

      Redis.new(OPTIONS).publish("foo", "s1")

      thread.join

      assert @subscribed
      assert_equal 1, @t1
      assert @unsubscribed
      assert_equal 0, @t2
      assert_equal "s1", @message
    end

    test "SUBSCRIBE within SUBSCRIBE" do
      listening = false

      @channels = []

      thread = Thread.new do
        @r.subscribe("foo") do |on|
          on.subscribe do |channel, total|
            @channels << channel

            @r.subscribe("bar") if channel == "foo"
            @r.unsubscribe if channel == "bar"
          end

          listening = true
        end
      end

      while !listening; end

      Redis.new(OPTIONS).publish("foo", "s1")

      thread.join

      assert_equal ["foo", "bar"], @channels
    end

    test "other commands within a SUBSCRIBE" do
      assert_raise RuntimeError do
        @r.subscribe("foo") do |on|
          on.subscribe do |channel, total|
            @r.set("bar", "s2")
          end
        end
      end
    end

    test "SUBSCRIBE without a block" do
      assert_raise LocalJumpError do
        @r.subscribe("foo")
      end
    end

    test "UNSUBSCRIBE without a SUBSCRIBE" do
      assert_raise RuntimeError do
        @r.unsubscribe
      end

      assert_raise RuntimeError do
        @r.punsubscribe
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
      assert Time.at(@r.lastsave) <= Time.now
    end
  end

  context "Remote server control commands" do
    test "INFO" do
      %w(last_save_time redis_version total_connections_received connected_clients total_commands_processed connected_slaves uptime_in_seconds used_memory uptime_in_days changes_since_last_save).each do |x|
        assert @r.info.keys.include?(x)
      end
    end

    test "MONITOR" do
      log = []

      t1 = Thread.new do
        Redis.new(OPTIONS).monitor do |line|
          log << line
          break if log.size == 3
        end
      end

      while log.empty?; end # Faster than sleep

      @r.set "foo", "s1"

      t1.join

      assert log[-1][%q{(db 15) "set" "foo" "s1"}]
    end

    test "ECHO" do
      assert_equal "foo bar baz\n", @r.echo("foo bar baz\n")
    end
  end

  context "Pipelining commands" do
    test "BULK commands" do
      @r.pipelined do
        @r.lpush "foo", "s1"
        @r.lpush "foo", "s2"
      end

      assert_equal 2, @r.llen("foo")
      assert_equal "s2", @r.lpop("foo")
      assert_equal "s1", @r.lpop("foo")
    end

    test "MULTI_BULK commands" do
      @r.pipelined do
        @r.mset("foo", "s1", "bar", "s2")
        @r.mset("baz", "s3", "qux", "s4")
      end

      assert_equal "s1", @r.get("foo")
      assert_equal "s2", @r.get("bar")
      assert_equal "s3", @r.get("baz")
      assert_equal "s4", @r.get("qux")
    end

    test "BULK and MULTI_BULK commands mixed" do
      @r.pipelined do
        @r.lpush "foo", "s1"
        @r.lpush "foo", "s2"
        @r.mset("baz", "s3", "qux", "s4")
      end

      assert_equal 2, @r.llen("foo")
      assert_equal "s2", @r.lpop("foo")
      assert_equal "s1", @r.lpop("foo")
      assert_equal "s3", @r.get("baz")
      assert_equal "s4", @r.get("qux")
    end

    test "MULTI_BULK and BULK commands mixed" do
      @r.pipelined do
        @r.mset("baz", "s3", "qux", "s4")
        @r.lpush "foo", "s1"
        @r.lpush "foo", "s2"
      end

      assert_equal 2, @r.llen("foo")
      assert_equal "s2", @r.lpop("foo")
      assert_equal "s1", @r.lpop("foo")
      assert_equal "s3", @r.get("baz")
      assert_equal "s4", @r.get("qux")
    end

    test "Pipelined with an empty block" do
      assert_nothing_raised do
        @r.pipelined do
        end
      end

      assert_equal 0, @r.dbsize
    end

    test "Returning the result of a pipeline" do
      result = @r.pipelined do
        @r.set "foo", "bar"
        @r.get "foo"
        @r.get "bar"
      end

      assert_equal ["OK", "bar", nil], result
    end
  end

  context "Unknown commands" do
    should "try to work" do
      assert_raises RuntimeError do
        @r.not_yet_implemented_command
      end
    end
  end

  context "Thread safety" do
    should "be thread safe" do
      @r = prepare Redis.new(OPTIONS.merge(:thread_safe => true))
      @r.client.disconnect

      r1, r2 = nil

      t1 = Thread.new do
        r1 = @r.client.process([:set, "foo", 1]) do
          sleep 1
          @r.client.send(:read)
        end
      end

      t2 = Thread.new do
        r2 = @r.client.process([:get, "foo"]) do
          @r.client.send(:read)
        end
      end

      t1.join
      t2.join

      assert_equal "OK", r1
      assert_equal "1", r2
    end
  end

  context "Encoding" do
    should "return properly encoded strings" do
      with_external_encoding("UTF-8") do
        @r.set "foo", "שלום"

        assert_equal "Shalom שלום", "Shalom " + @r.get("foo")
      end
    end
  end if defined?(Encoding)

  teardown do
    @r.client.disconnect if @r
  end
end
