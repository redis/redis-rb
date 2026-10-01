# frozen_string_literal: true

class Redis
  module Commands
    # The `BLESS` command family (Redis 8.12): per-key protection flags that
    # shield a key from memory-pressure actions. The only flag so far is
    # `NO-EVICT`, which excludes the key from the eviction policy.
    #
    # Flags are accepted as a Symbol or String in either spelling
    # (`:no_evict`, `"no-evict"`, `"NO-EVICT"`) and are sent uppercased with
    # dashes, as the server expects.
    module Bless
      # Protection flags understood by the server, in wire spelling.
      BLESS_FLAGS = %w[NO-EVICT].freeze

      # Return the active protection flags of a key.
      #
      # @example
      #   redis.set("foo", "bar")
      #   redis.bless_set("foo", :no_evict)
      #   redis.bless_get("foo")
      #     # => ["NO-EVICT"]
      #
      # @param [String] key
      # @return [Array<String>] the key's active flags, in wire spelling
      #   (e.g. `"NO-EVICT"`); empty when none are set
      def bless_get(key)
        send_command([:bless, "GET", key])
      end

      # Add a protection flag to a key.
      #
      # @example
      #   redis.bless_set("foo", :no_evict)
      #     # => true
      #   redis.bless_set("foo", :no_evict)
      #     # => false
      #
      # @param [String] key
      # @param [Symbol, String] flag one of {BLESS_FLAGS}, e.g. `:no_evict`
      # @return [Boolean] whether the key's flag set changed (`false` if the
      #   flag was already set)
      # @raise [ArgumentError] if the flag is not one of {BLESS_FLAGS}
      def bless_set(key, flag)
        send_command([:bless, "SET", key, _bless_flag(flag)], &Boolify)
      end

      # Remove a protection flag from a key.
      #
      # @example
      #   redis.bless_clear("foo", :no_evict)
      #     # => true
      #   redis.bless_clear("foo", :no_evict)
      #     # => false
      #
      # @param [String] key
      # @param [Symbol, String] flag one of {BLESS_FLAGS}, e.g. `:no_evict`
      # @return [Boolean] whether the key's flag set changed (`false` if the
      #   flag was already clear)
      # @raise [ArgumentError] if the flag is not one of {BLESS_FLAGS}
      def bless_clear(key, flag)
        send_command([:bless, "CLEAR", key, _bless_flag(flag)], &Boolify)
      end

      # Incrementally iterate the keys of the current database that carry the
      # given protection flag. Like `SCAN`, a full iteration is complete when
      # the returned cursor is `"0"`.
      #
      # @example Retrieve the first batch of keys blessed with NO-EVICT
      #   redis.bless_scan(0, :no_evict)
      #     # => ["17", ["key:1", "key:2"]]
      # @example Hint the batch size
      #   redis.bless_scan(17, :no_evict, count: 100)
      #     # => ["0", ["key:3"]]
      #
      # @param [String, Integer] cursor the cursor of the iteration
      # @param [Symbol, String] flag one of {BLESS_FLAGS}, e.g. `:no_evict`
      # @param [Hash] options
      # @option options [Integer] :count return about this many keys per call
      # @return [Array(String, Array<String>)] the next cursor and the keys found
      # @raise [ArgumentError] if the flag is not one of {BLESS_FLAGS}
      #
      # @note On `Redis::Cluster` the driver walks the nodes one by one, as it
      #   does for `SCAN`, encoding the node index into the returned cursor, so
      #   a full iteration covers every shard. Inside `pipelined`/`multi` the
      #   command is sent to a single node instead and only that node's keys
      #   are returned.
      def bless_scan(cursor, flag, count: nil)
        args = [:bless, "SCAN", cursor, _bless_flag(flag)]
        args << "COUNT" << Integer(count) if count

        send_command(args)
      end

      # Iterate every key of the current database that carries the given
      # protection flag, driving {#bless_scan} until the cursor wraps around.
      #
      # @example Collect all keys blessed with NO-EVICT (with possible duplicates)
      #   redis.bless_scan_each(:no_evict).to_a
      #     # => ["key:1", "key:2", "key:3"]
      # @example Execute a block for each blessed key
      #   redis.bless_scan_each(:no_evict, count: 100) { |key| puts key }
      #
      # @param [Symbol, String] flag one of {BLESS_FLAGS}, e.g. `:no_evict`
      # @param [Hash] options
      # @option options [Integer] :count return about this many keys per call
      # @return [Enumerator] an enumerator over all found keys when no block is given
      # @raise [ArgumentError] if the flag is not one of {BLESS_FLAGS}
      def bless_scan_each(flag, **options, &block)
        return to_enum(:bless_scan_each, flag, **options) unless block_given?

        cursor = 0
        loop do
          cursor, keys = bless_scan(cursor, flag, **options)
          keys.each(&block)
          break if cursor == "0"
        end
      end

      private

      # Normalize a user-supplied flag (`:no_evict`, `"no-evict"`, `"NO-EVICT"`)
      # to its wire spelling, rejecting anything the server does not know.
      def _bless_flag(flag)
        normalized = flag.to_s.upcase.tr("_", "-")
        unless BLESS_FLAGS.include?(normalized)
          raise ArgumentError, "flag must be one of #{BLESS_FLAGS.inspect}, got #{flag.inspect}"
        end

        normalized
      end
    end
  end
end
