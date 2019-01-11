# frozen_string_literal: true

require_relative '../redis'

class Redis
  # For backward compatibility
  HashRing = Distributed::HashRing

  # Partitioning with client side consistent hashing
  class Distributed
    # @param node_configs [Array<String, Hash>] List of nodes to contact
    # @param options [Hash] same as Redis constructor
    # @deprecated Use `Redis.new(distributed: { nodes: node_configs, tag: tag, ring: ring }, timeout: 10)` instead.
    def initialize(node_configs, options = {})
      options = options.dup
      tag = options.delete(:tag)
      ring = options.delete(:ring)
      options[:distributed] = { nodes: node_configs, tag: tag, ring: ring }
      @redis = Redis.new(options)
    end

    private

    def method_missing(name, *args, &block)
      @redis.public_send(name, *args, &block)
    end

    def respond_to_missing?(name, include_private)
      @redis.respond_to?(name, include_private)
    end
  end
end
