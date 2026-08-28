# frozen_string_literal: true

class Redis
  module KeyspaceNotifications
    # Builders for keyspace-notification channel names and psubscribe patterns.
    #
    # All builders return BINARY (ASCII-8BIT) encoded strings so that keys containing
    # arbitrary bytes concatenate safely. The +db:+ argument accepts a non-negative
    # Integer or the literal <tt>"*"</tt> (database wildcard, for pattern subscriptions).
    # The +key+/+event+ arguments may themselves contain glob characters when the
    # channel is meant to be used with +psubscribe+.
    #
    # @example Watch every event on keys under a prefix
    #   redis.psubscribe(Redis::KeyspaceNotifications::Channels.keyspace("user:*", db: 0)) { |on| ... }
    module Channels
      FAMILIES = {
        keyspace: "__keyspace@",
        keyevent: "__keyevent@",
        subkeyspace: "__subkeyspace@",
        subkeyevent: "__subkeyevent@",
        subkeyspaceitem: "__subkeyspaceitem@",
        subkeyspaceevent: "__subkeyspaceevent@"
      }.freeze

      module_function

      # Channel carrying every event happening to +key+; the message payload is the event name.
      #
      # @param key [String] key name or glob pattern
      # @param db [Integer, String] database index or "*"
      # @return [String] <tt>__keyspace@<db>__:<key></tt> (BINARY encoded)
      def keyspace(key, db: 0)
        build(:keyspace, db, key)
      end

      # Channel carrying every key receiving +event+; the message payload is the key name.
      #
      # @param event [String] event name (e.g. "expired") or glob pattern
      # @param db [Integer, String] database index or "*"
      # @return [String] <tt>__keyevent@<db>__:<event></tt> (BINARY encoded)
      def keyevent(event, db: 0)
        build(:keyevent, db, event)
      end

      # Subkey channel for +key+; the payload carries the event and the affected subkeys.
      # Requires Redis 8.8+ with the `S` flag in `notify-keyspace-events`.
      #
      # @param key [String] key name or glob pattern
      # @param db [Integer, String] database index or "*"
      # @return [String] <tt>__subkeyspace@<db>__:<key></tt> (BINARY encoded)
      def subkeyspace(key, db: 0)
        build(:subkeyspace, db, key)
      end

      # Subkey channel for +event+; the payload carries the key and the affected subkeys.
      # Requires Redis 8.8+ with the `T` flag in `notify-keyspace-events`.
      #
      # @param event [String] event name (e.g. "hdel") or glob pattern
      # @param db [Integer, String] database index or "*"
      # @return [String] <tt>__subkeyevent@<db>__:<event></tt> (BINARY encoded)
      def subkeyevent(event, db: 0)
        build(:subkeyevent, db, event)
      end

      # Exact key + subkey channel; the payload is the event name. The server only emits
      # this family for keys that contain no newline, so such keys are rejected here.
      # Requires Redis 8.8+ with the `I` flag in `notify-keyspace-events`.
      #
      # @param key [String] key name (must not contain "\n")
      # @param subkey [String] subkey (e.g. hash field) or glob pattern
      # @param db [Integer, String] database index or "*"
      # @return [String] <tt>__subkeyspaceitem@<db>__:<key>\n<subkey></tt> (BINARY encoded)
      # @raise [ArgumentError] when +key+ contains "\n"
      def subkeyspaceitem(key, subkey, db: 0)
        raise ArgumentError, "subkeyspaceitem keys must not contain \"\\n\"" if key.include?("\n")

        channel = build(:subkeyspaceitem, db, key)
        channel << "\n" << subkey.b
      end

      # Event + key channel; the payload carries the affected subkeys. The key part may be
      # a glob pattern (e.g. <tt>subkeyspaceevent("hset", "user:*")</tt> with psubscribe).
      # Requires Redis 8.8+ with the `V` flag in `notify-keyspace-events`.
      #
      # @param event [String] event name (e.g. "hset") or glob pattern
      # @param key [String] key name or glob pattern
      # @param db [Integer, String] database index or "*"
      # @return [String] <tt>__subkeyspaceevent@<db>__:<event>|<key></tt> (BINARY encoded)
      def subkeyspaceevent(event, key, db: 0)
        channel = build(:subkeyspaceevent, db, event)
        channel << "|" << key.b
      end

      # Escapes Redis glob metacharacters (`*`, `?`, `[`, `]`, `\`) so a literal
      # key can be embedded in a psubscribe pattern without matching other keys.
      #
      # @param value [String]
      # @return [String] the escaped value (BINARY encoded)
      def glob_escape(value)
        # The replacement must be built in BINARY: interpolating a high byte into a
        # UTF-8 literal raises Encoding::CompatibilityError, and keys are arbitrary
        # bytes by contract.
        value.b.gsub(/[*?\[\]\\]/) { |char| "\\".b << char }
      end

      # @api private
      def build(family, db, suffix)
        validate_db!(db)
        prefix = "#{FAMILIES.fetch(family)}#{db}__:"
        prefix.b << suffix.b
      end

      # @api private
      def validate_db!(db)
        return if db == "*" || (db.is_a?(Integer) && db >= 0)

        raise ArgumentError, "db must be a non-negative Integer or \"*\", got #{db.inspect}"
      end
    end
  end
end
