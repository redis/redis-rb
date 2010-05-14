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
      @tag = options.delete(:tag) || /^\{(.+?)\}/
      @default_options = options
      @ring = HashRing.new urls.map { |url| Redis.connect(options.merge(:url => url)) }
      @subscribed_node = nil
    end

    def node_for(key)
      @ring.get_node(key_tag(key) || key)
    end

    def nodes
      @ring.nodes
    end

    def add_node(url)
      @ring.add_node Redis.connect(@default_options.merge(:url => url))
    end

    def quit
      on_each_node :quit
    end

    def select(db)
      on_each_node :select, db
    end

    def ping
      on_each_node :ping
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
      ensure_same_node(:rename, old_name, new_name) do |node|
        node.rename(old_name, new_name)
      end
    end

    def renamenx(old_name, new_name)
      ensure_same_node(:renamenx, old_name, new_name) do |node|
        node.renamenx(old_name, new_name)
      end
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

    def append(key, value)
      node_for(key).append(key, value)
    end

    def substr(key, start, stop)
      node_for(key).substr(key, start, stop)
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
      ensure_same_node(:rpoplpush, source, destination) do |node|
        node.rpoplpush(source, destination)
      end
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
      ensure_same_node(:smove, source, destination) do |node|
        node.smove(source, destination, member)
      end
    end

    def scard(key)
      node_for(key).scard(key)
    end

    def sismember(key, member)
      node_for(key).sismember(key, member)
    end

    def sinter(*keys)
      ensure_same_node(:sinter, *keys) do |node|
        node.sinter(*keys)
      end
    end

    def sinterstore(destination, *keys)
      ensure_same_node(:sinterstore, destination, *keys) do |node|
        node.sinterstore(destination, *keys)
      end
    end

    def sunion(*keys)
      ensure_same_node(:sunion, *keys) do |node|
        node.sunion(*keys)
      end
    end

    def sunionstore(destination, *keys)
      ensure_same_node(:sunionstore, destination, *keys) do |node|
        node.sunionstore(destination, *keys)
      end
    end

    def sdiff(*keys)
      ensure_same_node(:sdiff, *keys) do |node|
        node.sdiff(*keys)
      end
    end

    def sdiffstore(destination, *keys)
      ensure_same_node(:sdiffstore, destination, *keys) do |node|
        node.sdiffstore(destination, *keys)
      end
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

    def zrange(key, start, stop, options = {})
      node_for(key).zrange(key, start, stop, options)
    end

    def zrank(key, member)
      node_for(key).zrank(key, member)
    end

    def zrevrank(key, member)
      node_for(key).zrevrank(key, member)
    end

    def zrevrange(key, start, stop, options = {})
      node_for(key).zrevrange(key, start, stop, options)
    end

    def zremrangebyscore(key, min, max)
      node_for(key).zremrangebyscore(key, min, max)
    end

    def zremrangebyrank(key, start, stop)
      node_for(key).zremrangebyrank(key, start, stop)
    end

    def zrangebyscore(key, min, max, options = {})
      node_for(key).zrangebyscore(key, min, max, options)
    end

    def zcard(key)
      node_for(key).zcard(key)
    end

    def zscore(key, member)
      node_for(key).zscore(key, member)
    end

    def zinterstore(destination, keys, options = {})
      ensure_same_node(:zinterstore, destination, *keys) do |node|
        node.zinterstore(destination, keys, options)
      end
    end

    def zunionstore(destination, keys, options = {})
      ensure_same_node(:zunionstore, destination, *keys) do |node|
        node.zunionstore(destination, keys, options)
      end
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

    def hincrby(key, field, increment)
      node_for(key).hincrby(key, field, increment)
    end

    def sort(key, options = {})
      keys = [key, options[:by], options[:store], *Array(options[:get])].compact

      ensure_same_node(:sort, *keys) do |node|
        node.sort(key, options)
      end
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
      node_for(channel).publish(channel, message)
    end

    def subscribed?
      !! @subscribed_node
    end

    def unsubscribe(*channels)
      raise RuntimeError, "Can't unsubscribe if not subscribed." unless subscribed?
      @subscribed_node.unsubscribe(*channels)
    end

    def subscribe(channel, *channels, &block)
      if channels.empty?
        @subscribed_node = node_for(channel)
        @subscribed_node.subscribe(channel, &block)
      else
        ensure_same_node(:subscribe, channel, *channels) do |node|
          @subscribed_node = node
          node.subscribe(channel, *channels, &block)
        end
      end
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

    def key_tag(key)
      key[@tag, 1] if @tag
    end

    def ensure_same_node(command, *keys)
      tags = keys.map { |key| key_tag(key) }

      raise CannotDistribute, command if !tags.all? || tags.uniq.size != 1

      yield(node_for(keys.first))
    end
  end
end
