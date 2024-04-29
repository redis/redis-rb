# frozen_string_literal: true

require "redis"

class Redis
  class Cluster < ::Redis
    # Raised when client connected to redis as cluster mode
    # and failed to fetch cluster state information by commands.
    class InitialSetupError < BaseError
    end

    # Raised when client connected to redis as cluster mode
    # and some cluster subcommands were called.
    class OrchestrationCommandNotSupported < BaseError
      def initialize(command, subcommand = '')
        str = [command, subcommand].map(&:to_s).reject(&:empty?).join(' ').upcase
        msg = "#{str} command should be used with care "\
              'only by applications orchestrating Redis Cluster, like redis-trib, '\
              'and the command if used out of the right context can leave the cluster '\
              'in a wrong state or cause data loss.'
        super(msg)
      end
    end

    # Raised when error occurs on any node of cluster.
    class CommandErrorCollection < BaseError
      attr_reader :errors

      # @param errors [Hash{String => Redis::CommandError}]
      # @param error_message [String]
      def initialize(errors, error_message = 'Command errors were replied on any node')
        @errors = errors
        super(error_message)
      end
    end

    # Raised when cluster client can't select node.
    class AmbiguousNodeError < BaseError
    end

    class TransactionConsistencyError < BaseError
    end

    class NodeMightBeDown < BaseError
    end

    def connection
      raise NotImplementedError, "Redis::Cluster doesn't implement #connection"
    end

    # Create a new client instance
    #
    # @param [Hash] options
    # @option options [Float] :timeout (5.0) timeout in seconds
    # @option options [Float] :connect_timeout (same as timeout) timeout for initial connect in seconds
    # @option options [Symbol] :driver Driver to use, currently supported: `:ruby`, `:hiredis`
    # @option options [Integer, Array<Integer, Float>] :reconnect_attempts Number of attempts trying to connect,
    #   or a list of sleep duration between attempts.
    # @option options [Boolean] :inherit_socket (false) Whether to use socket in forked process or not
    # @option options [Array<String, Hash{Symbol => String, Integer}>] :nodes List of cluster nodes to contact
    # @option options [Boolean] :replica Whether to use readonly replica nodes in Redis Cluster or not
    # @option options [Symbol] :replica_affinity scale reading strategy, currently supported: `:random`, `:latency`
    # @option options [String] :fixed_hostname Specify a FQDN if cluster mode enabled and
    #   client has to connect nodes via single endpoint with SSL/TLS
    # @option options [Class] :connector Class of custom connector
    #
    # @return [Redis::Cluster] a new client instance
    def initialize(*) # rubocop:disable Lint/UselessMethodDefinition
      super
    end
    ruby2_keywords :initialize if respond_to?(:ruby2_keywords, true)

    # Sends `CLUSTER *` command to random node and returns its reply.
    #
    # @see https://redis.io/commands#cluster Reference of cluster command
    #
    # @param subcommand [String, Symbol] the subcommand of cluster command
    #   e.g. `:slots`, `:nodes`, `:slaves`, `:info`
    #
    # @return [Object] depends on the subcommand
    def cluster(subcommand, *args)
      subcommand = subcommand.to_s.downcase
      block = case subcommand
      when 'slots'
        HashifyClusterSlots
      when 'nodes'
        HashifyClusterNodes
      when 'slaves'
        HashifyClusterSlaves
      when 'info'
        HashifyInfo
      else
        Noop
      end

      send_command([:cluster, subcommand] + args, &block)
    end

    # Watch the given keys to determine execution of the MULTI/EXEC block.
    #
    # Using a block is required for a cluster client. It's different from a standalone client.
    # And you should use the block argument as a receiver if you call commands.
    #
    # An `#unwatch` is automatically issued if an exception is raised within the
    # block that is a subclass of StandardError and is not a ConnectionError.
    #
    # @param keys [String, Array<String>] one or more keys to watch
    # @return [Object] returns the return value of the block
    #
    # @example A typical use case.
    #   # The client is an instance of the internal adapter for the optimistic locking
    #   redis.watch("{my}key") do |client|
    #     if client.get("{my}key") == "some value"
    #       # The tx is an instance of the internal adapter for the transaction
    #       client.multi do |tx|
    #         tx.set("{my}key", "other value")
    #         tx.incr("{my}counter")
    #       end
    #     else
    #       client.unwatch
    #     end
    #   end
    #   #=> ["OK", 6]
    def watch(*keys, &block)
      synchronize { |c| c.watch(*keys, &block) }
    end

    private

    def initialize_client(options)
      cluster_config = RedisClient.cluster(**options, protocol: 2, client_implementation: ::Redis::Cluster::Client)
      cluster_config.new_client
    end
  end
end

require "redis/cluster/client"
