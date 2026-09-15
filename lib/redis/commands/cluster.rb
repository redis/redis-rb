# frozen_string_literal: true

class Redis
  module Commands
    module Cluster
      # Sends `CLUSTER *` command to random node and returns its reply.
      #
      # @see https://redis.io/commands#cluster Reference of cluster command
      #
      # @param subcommand [String, Symbol] the subcommand of cluster command
      #   e.g. `:slots`, `:nodes`, `:slaves`, `:info`, `:'slot-stats'`
      #
      # @example Per-slot usage stats for a range (Redis 8.2)
      #   redis.cluster('slot-stats', 'SLOTSRANGE', 0, 100)
      #     # => [[0, {"key-count" => 1}], [1, {"key-count" => 0}], ...]
      # @example Top slots by key count (Redis 8.2)
      #   redis.cluster('slot-stats', 'ORDERBY', 'key-count', 'LIMIT', 3, 'DESC')
      #
      # @return [Object] depends on the subcommand
      def cluster(subcommand, *args)
        block = subcommand.to_s.downcase == 'slot-stats' ? HashifyClusterSlotStats : Noop
        send_command([:cluster, subcommand] + args, &block)
      end

      # Sends `ASKING` command to random node and returns its reply.
      #
      # @see https://redis.io/topics/cluster-spec#ask-redirection ASK redirection
      #
      # @return [String] `'OK'`
      def asking
        send_command(%i[asking])
      end
    end
  end
end
