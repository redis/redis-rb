# frozen_string_literal: true

class Redis
  module Commands
    # The `BLESS` command family (Redis 8.12): per-key protection flags that
    # shield a key from memory-pressure actions. The only flag so far is
    # `NO-EVICT`, which excludes the key from the eviction policy.
    #
    # Flags are passed to the server verbatim: no client-side validation or
    # normalization is done, so spell them the way the server does
    # (`"NO-EVICT"`). An unknown flag is rejected by the server with a
    # {Redis::CommandError}.
    module Bless
      # Return the active protection flags of a key.
      #
      # @example
      #   redis.set("foo", "bar")
      #   redis.bless_set("foo", "NO-EVICT")
      #   redis.bless_get("foo")
      #     # => ["NO-EVICT"]
      #
      # @param [String] key
      # @return [Array<String>] the key's active flags (e.g. `"NO-EVICT"`);
      #   empty when none are set
      def bless_get(key)
        send_command([:bless, "GET", key])
      end

      # Add a protection flag to a key.
      #
      # @example
      #   redis.bless_set("foo", "NO-EVICT")
      #     # => true
      #   redis.bless_set("foo", "NO-EVICT")
      #     # => false
      #
      # @param [String] key
      # @param [String] flag the protection flag, e.g. `"NO-EVICT"`
      # @return [Boolean] whether the key's flag set changed (`false` if the
      #   flag was already set)
      def bless_set(key, flag)
        send_command([:bless, "SET", key, flag], &Boolify)
      end

      # Remove a protection flag from a key.
      #
      # @example
      #   redis.bless_clear("foo", "NO-EVICT")
      #     # => true
      #   redis.bless_clear("foo", "NO-EVICT")
      #     # => false
      #
      # @param [String] key
      # @param [String] flag the protection flag, e.g. `"NO-EVICT"`
      # @return [Boolean] whether the key's flag set changed (`false` if the
      #   flag was already clear)
      def bless_clear(key, flag)
        send_command([:bless, "CLEAR", key, flag], &Boolify)
      end

      # Incrementally iterate the keys of the current database that carry the
      # given protection flag. Like `SCAN`, a full iteration is complete when
      # the returned cursor is `"0"`.
      #
      # @example Retrieve the first batch of keys blessed with NO-EVICT
      #   redis.bless_scan(0, "NO-EVICT")
      #     # => ["17", ["key:1", "key:2"]]
      # @example Hint the batch size
      #   redis.bless_scan(17, "NO-EVICT", count: 100)
      #     # => ["0", ["key:3"]]
      #
      # @param [String, Integer] cursor the cursor of the iteration
      # @param [String] flag the protection flag, e.g. `"NO-EVICT"`
      # @param [Hash] options
      # @option options [Integer] :count return about this many keys per call
      # @return [Array(String, Array<String>)] the next cursor and the keys found
      #
      # @note On `Redis::Cluster` the driver walks the nodes one by one, as it
      #   does for `SCAN`, encoding the node index into the returned cursor, so
      #   a full iteration covers every shard. Inside `pipelined`/`multi` the
      #   command is sent to a single node instead and only that node's keys
      #   are returned.
      def bless_scan(cursor, flag, count: nil)
        args = [:bless, "SCAN", cursor, flag]
        args << "COUNT" << Integer(count) if count

        send_command(args)
      end

      # Iterate every key of the current database that carries the given
      # protection flag, driving {#bless_scan} until the cursor wraps around.
      #
      # @example Collect all keys blessed with NO-EVICT (with possible duplicates)
      #   redis.bless_scan_each("NO-EVICT").to_a
      #     # => ["key:1", "key:2", "key:3"]
      # @example Execute a block for each blessed key
      #   redis.bless_scan_each("NO-EVICT", count: 100) { |key| puts key }
      #
      # @param [String] flag the protection flag, e.g. `"NO-EVICT"`
      # @param [Hash] options
      # @option options [Integer] :count return about this many keys per call
      # @return [Enumerator] an enumerator over all found keys when no block is given
      def bless_scan_each(flag, **options, &block)
        return to_enum(:bless_scan_each, flag, **options) unless block_given?

        cursor = 0
        loop do
          cursor, keys = bless_scan(cursor, flag, **options)
          keys.each(&block)
          break if cursor == "0"
        end
      end
    end
  end
end
