# frozen_string_literal: true

class Redis
  module KeyspaceNotifications
    # A parsed keyspace, keyevent or subkey notification.
    #
    # Immutable value object produced by {Parser.parse}. +key+ and the +subkeys+
    # elements are BINARY (ASCII-8BIT) encoded strings, because Redis keys and
    # subkeys may contain arbitrary bytes; call +force_encoding+ on them if your
    # application guarantees UTF-8 keys.
    class Notification
      FAMILIES = %i[keyspace keyevent subkeyspace subkeyevent subkeyspaceitem subkeyspaceevent].freeze

      # @return [Symbol] the channel family, one of {FAMILIES}
      # @return [Integer, String] the database the event happened in, or "*" when the
      #   channel itself carried a database wildcard
      # @return [String] the event name (e.g. "set", "expired", "hdel"). Opaque: new
      #   server events flow through without a library update
      # @return [String] the affected key (BINARY encoded)
      # @return [Array<String>] the affected subkeys, in server order with duplicates
      #   preserved; empty for keyspace/keyevent, exactly one for subkeyspaceitem
      # @return [String] the raw pub/sub channel the notification arrived on
      # @return [String] the raw pub/sub message payload
      # @return [String, nil] the psubscribe pattern that matched, when delivered via pmessage
      attr_reader :family, :db, :event, :key, :subkeys, :channel, :payload, :pattern

      # @param family [Symbol] one of {FAMILIES}
      # @param db [Integer, String] database index or "*"
      # @param event [String] event name
      # @param key [String] affected key
      # @param channel [String] raw channel
      # @param payload [String] raw payload
      # @param subkeys [Array<String>] affected subkeys
      # @param pattern [String, nil] matched psubscribe pattern
      def initialize(family:, db:, event:, key:, channel:, payload:, subkeys: [], pattern: nil)
        @family = family
        @db = db
        @event = event
        @key = key
        @subkeys = subkeys.freeze
        @channel = channel
        @payload = payload
        @pattern = pattern
      end

      # Convenience accessor for single-subkey families (subkeyspaceitem).
      #
      # @return [String, nil] the first subkey, or nil when there are none
      def subkey
        @subkeys.first
      end

      # @return [Boolean] whether this notification belongs to one of the Redis 8.8
      #   subkey channel families (and therefore may carry subkeys)
      def subkey_family?
        @family != :keyspace && @family != :keyevent
      end

      # @return [Hash{Symbol => Object}] all fields as a hash
      def to_h
        {
          family: @family,
          db: @db,
          event: @event,
          key: @key,
          subkeys: @subkeys,
          channel: @channel,
          payload: @payload,
          pattern: @pattern
        }
      end

      # @param other [Object] the object to compare against
      # @return [Boolean] whether +other+ is a Notification with equal fields
      def ==(other)
        other.is_a?(Notification) && to_h == other.to_h
      end
      alias eql? ==

      # @return [Integer] a hash derived from all fields
      def hash
        to_h.hash
      end
    end
  end
end
