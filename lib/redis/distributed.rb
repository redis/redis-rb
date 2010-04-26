require "redis/hash_ring"

class Redis
  class Distributed

    class CannotDistribute < RuntimeError
      def initialize(command)
        @command = command
      end

      def message
        "#{@command.to_s.upcase} cannot be used in Redis::Distributed because the keys involved need to be on the same server or because we cannot guarantee that the operation will be atomic."
      end
    end

    attr_reader :ring

    def initialize(urls, options = {})
      @tag = options.delete(:tag) || /^{(.+?)}/
      @default_options = options
      @ring = HashRing.new urls.map { |url| Redis.connect(options.merge(:url => url)) }
    end

    def node_for(key)
      @ring.get_node(key[@tag, 1] || key)
    end

    def nodes
      @ring.nodes
    end

    def add_node(url)
      @ring.add_node Redis.connect(@default_options.merge(:url => url))
    end

    def quit
      on_each_node :quit
    rescue Errno::ECONNRESET
    end

    def select(db)
      on_each_node :select, db
    end

    def ping
      on_each_node :ping
    end

    def quit
      on_each_node :quit
    end

    def flushall
      on_each_node :flushall
    end

    def exists(key)
      node_for(key).exists(key)
    end

    def del(*keys)
      on_each_node(:del, *keys)
    end

    def type(key)
      node_for(key).type(key)
    end

    def keys(glob = "*")
      on_each_node(:keys, glob).flatten
    end

    def randomkey
      raise CannotDistribute, :randomkey
    end

    def rename(old_name, new_name)
      raise CannotDistribute, :rename
    end

    def renamenx(old_name, new_name)
      raise CannotDistribute, :renamenx
    end

    def dbsize
      on_each_node :dbsize
    end

    def expire(key, seconds)
      node_for(key).expire(key, seconds)
    end

    def expireat(key, unix_time)
      node_for(key).expireat(key, unix_time)
    end

    def ttl(key)
      node_for(key).ttl(key)
    end

    def move(key, db)
      node_for(key).move(key, db)
    end

    def flushdb
      on_each_node :flushdb
    end

    def set(key, value)
      node_for(key).set(key, value)
    end

    def setex(key, ttl, value)
      node_for(key).setex(key, ttl, value)
    end

    def get(key)
      node_for(key).get(key)
    end

    def getset(key, value)
      node_for(key).getset(key, value)
    end

    def [](key)
      get(key)
    end

    def []=(key,value)
      set(key, value)
    end

    def mget(*keys)
      raise CannotDistribute, :mget
    end

    def mapped_mget(*keys)
      raise CannotDistribute, :mapped_mget
    end

    def setnx(key, value)
      node_for(key).setnx(key, value)
    end

    def mset(*args)
      raise CannotDistribute, :mset
    end

    def mapped_mset(hash)
      mset(*hash.to_a.flatten)
    end

    def msetnx(*args)
      raise CannotDistribute, :msetnx
    end

    def mapped_msetnx(hash)
      raise CannotDistribute, :mapped_msetnx
    end

    def incr(key)
      node_for(key).incr(key)
    end

    def incrby(key, increment)
      node_for(key).incrby(key, increment)
    end

    def decr(key)
      node_for(key).decr(key)
    end

    def decrby(key, decrement)
      node_for(key).decrby(key, decrement)
    end

    def rpush(key, value)
      node_for(key).rpush(key, value)
    end

    def lpush(key, value)
      node_for(key).lpush(key, value)
    end

    def llen(key)
      node_for(key).llen(key)
    end

    def lrange(key, start, stop)
      node_for(key).lrange(key, start, stop)
    end

    def ltrim(key, start, stop)
      node_for(key).ltrim(key, start, stop)
    end

    def lindex(key, index)
      node_for(key).lindex(key, index)
    end

    def lset(key, index, value)
      node_for(key).lset(key, index, value)
    end

    def lrem(key, count, value)
      node_for(key).lrem(key, count, value)
    end

    def lpop(key)
      node_for(key).lpop(key)
    end

    def rpop(key)
      node_for(key).rpop(key)
    end

    def rpoplpush(source, destination)
      raise CannotDistribute, :rpoplpush
    end

    def blpop(key, timeout)
      node_for(key).blpop(key, timeout)
    end

    def brpop(key, timeout)
      node_for(key).brpop(key, timeout)
    end

    def sadd(key, value)
      node_for(key).sadd(key, value)
    end

    def srem(key, value)
      node_for(key).srem(key, value)
    end

    def spop(key)
      node_for(key).spop(key)
    end

    def smove(source, destination, member)
      raise CannotDistribute, :smove
    end

    def scard(key)
      node_for(key).scard(key)
    end

    def sismember(key, member)
      node_for(key).sismember(key, member)
    end

    def sinter(*keys)
      raise CannotDistribute, :sinter
    end

    def sinterstore(destination, *keys)
      raise CannotDistribute, :sinterstore
    end

    def sunion(*keys)
      raise CannotDistribute, :sunion
    end

    def sunionstore(*keys)
      raise CannotDistribute, :sunionstore
    end

    def sdiff(*keys)
      raise CannotDistribute, :sdiff
    end

    def sdiffstore(*keys)
      raise CannotDistribute, :sdiffstore
    end

    def smembers(key)
      node_for(key).smembers(key)
    end

    def srandmember(key)
      node_for(key).srandmember(key)
    end

    def zadd(key, score, member)
      node_for(key).zadd(key, score, member)
    end

    def zrem(key, member)
      node_for(key).zrem(key, member)
    end

    def zincrby(key, increment, member)
      node_for(key).zincrby(key, increment, member)
    end

    def zrange(key, start, stop, with_scores = false)
      if with_scores
        node_for(key).zrange(key, start, stop, "WITHSCORES")
      else
        node_for(key).zrange(key, start, stop)
      end
    end

    def zrevrange(key, start, stop, with_scores = false)
      if with_scores
        node_for(key).zrevrange(key, start, stop, "WITHSCORES")
      else
        node_for(key).zrevrange(key, start, stop)
      end
    end

    def zrangebyscore(key, min, max)
      node_for(key).zrangebyscore(key, min, max)
    end

    def zcard(key)
      node_for(key).zcard(key)
    end

    def zscore(key, member)
      node_for(key).zscore(key, member)
    end

    def hset(key, field, value)
      node_for(key).hset(key, field, value)
    end

    def hget(key, field)
      node_for(key).hget(key, field)
    end

    def hdel(key, field)
      node_for(key).hdel(key, field)
    end

    def hexists(key, field)
      node_for(key).hexists(key, field)
    end

    def hlen(key)
      node_for(key).hlen(key)
    end

    def hkeys(key)
      node_for(key).hkeys(key)
    end

    def hvals(key)
      node_for(key).hvals(key)
    end

    def hgetall(key)
      node_for(key).hgetall(key)
    end

    def hmset(key, *attrs)
      node_for(key).hmset(key, *attrs)
    end

    def sort(key, options = {})
      raise CannotDistribute, :sort
    end

    def multi(&block)
      raise CannotDistribute, :multi
    end

    def exec
      raise CannotDistribute, :exec
    end

    def discard
      raise CannotDistribute, :discard
    end

    def publish(channel, message)
      raise NotImplementedError
    end

    def unsubscribe(*channels)
      raise NotImplementedError
    end

    def subscribe(*channels, &block)
      raise NotImplementedError
    end

    def punsubscribe(*channels)
      raise NotImplementedError
    end

    def psubscribe(*channels, &block)
      raise NotImplementedError
    end

    def save
      on_each_node :save
    end

    def bgsave
      on_each_node :bgsave
    end

    def lastsave
      on_each_node :lastsave
    end

    def info
      on_each_node :info
    end

    def monitor
      raise NotImplementedError
    end

    def echo(value)
      on_each_node :echo, value
    end

    def pipelined
      raise CannotDistribute, :pipelined
    end

  protected

    def on_each_node(command, *args)
      nodes.map do |node|
        node.send(command, *args)
      end
    end

    def node_index_for(key)
      nodes.index(node_for(key))
    end
  end
end
