require 'redis/hash_ring'

class Redis
  class DistRedis
    attr_reader :ring
    def initialize(opts={})
      hosts = []

      db = opts[:db] || nil
      timeout = opts[:timeout] || nil

      raise "No hosts given" unless opts[:hosts]

      opts[:hosts].each do |h|
        host, port = h.split(':')
        hosts << Client.new(:host => host, :port => port, :db => db, :timeout => timeout)
      end

      @ring = HashRing.new hosts
    end

    def node_for_key(key)
      key = $1 if key =~ /\{(.*)?\}/
      @ring.get_node(key)
    end

    def add_server(server)
      server, port = server.split(':')
      @ring.add_node Client.new(:host => server, :port => port)
    end

    def method_missing(sym, *args, &blk)
      if redis = node_for_key(args.first.to_s)
        redis.send sym, *args, &blk
      else
        super
      end
    end

    def node_keys(glob)
      @ring.nodes.map do |red|
        red.keys(glob)
      end
    end

    def keys(glob)
      node_keys(glob).flatten
    end

    def save
      on_each_node :save
    end

    def bgsave
      on_each_node :bgsave
    end

    def quit
      on_each_node :quit
    end

    def flush_all
      on_each_node :flush_all
    end
    alias_method :flushall, :flush_all

    def flush_db
      on_each_node :flush_db
    end
    alias_method :flushdb, :flush_db

    def delete_cloud!
      @ring.nodes.each do |red|
        red.keys("*").each do |key|
          red.delete key
        end
      end
    end

    def on_each_node(command, *args)
      @ring.nodes.each do |red|
        red.send(command, *args)
      end
    end

    def mset()

    end

    def mget(*keyz)
      results = {}
      kbn = keys_by_node(keyz)
      kbn.each do |node, node_keyz|
        node.mapped_mget(*node_keyz).each do |k, v|
          results[k] = v
        end
      end
      keyz.flatten.map { |k| results[k] }
    end

    def keys_by_node(*keyz)
      keyz.flatten.inject({}) do |kbn, k|
        node = node_for_key(k)
        next if kbn[node] && kbn[node].include?(k)
        kbn[node] ||= []
        kbn[node] << k
        kbn
      end
    end

    def type(key)
      method_missing(:type, key)
    end
  end
end

# For backwards compatibility
DistRedis = Redis::DistRedis
