# frozen_string_literal: true

require_relative '../errors'
require_relative 'node_key'
require 'uri'

class Redis
  class Cluster
    # Keep options for Redis Cluster Client
    class Option
      DEFAULT_SCHEME = 'redis'
      SECURE_SCHEME = 'rediss'
      VALID_SCHEMES = [DEFAULT_SCHEME, SECURE_SCHEME].freeze

      def initialize(options)
        options = options.dup
        node_addrs = options.delete(:cluster)
        @node_opts = build_node_options(node_addrs)
        @replica = options.delete(:replica) == true
        add_common_node_option_if_needed(options, @node_opts, :scheme)
        add_common_node_option_if_needed(options, @node_opts, :password)
        @options = options
      end

      def per_node_key
        @node_opts.map { |opt| [NodeKey.build_from_host_port(opt[:host], opt[:port]), @options.merge(opt)] }
                  .to_h
      end

      def use_replica?
        @replica
      end

      def update_node(addrs)
        @node_opts = build_node_options(addrs)
      end

      def add_node(host, port)
        @node_opts << { host: host, port: port }
      end

      private

      def build_node_options(addrs)
        raise InvalidClientOptionError, 'Redis option of `cluster` must be an Array' unless addrs.is_a?(Array)
        addrs.map { |addr| parse_node_addr(addr) }
      end

      def parse_node_addr(addr)
        case addr
        when String
          parse_node_url(addr)
        when Hash
          parse_node_option(addr)
        else
          raise InvalidClientOptionError, 'Redis option of `cluster` must includes String or Hash'
        end
      end

      def parse_node_url(addr)
        uri = URI(addr)
        raise InvalidClientOptionError, "Invalid uri scheme #{addr}" unless VALID_SCHEMES.include?(uri.scheme)

        db = uri.path.split('/')[1]&.to_i
        { scheme: uri.scheme, password: uri.password, host: uri.host, port: uri.port, db: db }.reject { |_, v| v.nil? }
      rescue URI::InvalidURIError => err
        raise InvalidClientOptionError, err.message
      end

      def parse_node_option(addr)
        addr = addr.map { |k, v| [k.to_sym, v] }.to_h
        raise InvalidClientOptionError, 'Redis option of `cluster` must includes `:host` and `:port` keys' if addr.values_at(:host, :port).any?(&:nil?)

        addr
      end

      # Redis cluster node returns only host and port information.
      # So we should complement additional information such as:
      #   scheme, password and so on.
      def add_common_node_option_if_needed(options, node_opts, key)
        return options if options[key].nil? && node_opts.first[key].nil?

        options[key] ||= node_opts.first[key]
      end
    end
  end
end
