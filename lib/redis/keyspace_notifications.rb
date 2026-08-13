# frozen_string_literal: true

class Redis
  # Keyspace, keyevent and (Redis 8.8+) subkey notification support, layered on pub/sub.
  #
  # Layer 1 — {Channels} builders and {Parser} are usable directly inside the existing
  # subscribe/psubscribe DSL. Layer 2 — {Manager} (built via {Redis#keyspace_notifications})
  # owns a dedicated connection and background thread and dispatches parsed {Notification}
  # objects to handlers.
  #
  # Notifications must be enabled on the server via the `notify-keyspace-events`
  # configuration (a server-side, per-node setting — this library deliberately does not
  # set it for you). Notification channels are emitted by the server; do not PUBLISH to
  # them manually. See specs/keyspace-notifications/keyspace-notifications.md.
  module KeyspaceNotifications
    # Raised when a message on a notification channel cannot be decoded.
    class ParseError < BaseError
      # @return [String, nil] the raw channel the message arrived on
      # @return [String, nil] the raw message payload
      attr_reader :channel, :payload

      # @param message [String] the error message
      # @param channel [String, nil] the raw channel
      # @param payload [String, nil] the raw payload
      def initialize(message, channel: nil, payload: nil)
        super(message)
        @channel = channel
        @payload = payload
      end
    end
  end

  # Build a keyspace-notification manager. The manager owns a dedicated connection
  # (duplicated from this client's options) and a background listener thread; the
  # calling client remains fully usable for commands.
  #
  # @param error_handler [#call, nil] receives every background error (parse errors,
  #   handler exceptions, connection loss); defaults to warning on $stderr
  # @param reconnect_attempts [Integer, Array<Integer, Float>] number of attempts trying
  #   to reconnect and re-subscribe after losing the connection (with no sleep in
  #   between), or a list of sleep durations between attempts — the same semantics as
  #   the `reconnect_attempts` client option. Defaults to an exponential
  #   0.5s → 30s ladder of 10 attempts; the budget resets after every healthy session
  # @return [KeyspaceNotifications::Manager]
  def keyspace_notifications(error_handler: nil, reconnect_attempts: KeyspaceNotifications::Manager::DEFAULT_RECONNECT_ATTEMPTS)
    KeyspaceNotifications::Manager.new(redis: dup, error_handler: error_handler, reconnect_attempts: reconnect_attempts)
  end
end

require "redis/keyspace_notifications/channels"
require "redis/keyspace_notifications/notification"
require "redis/keyspace_notifications/parser"
require "redis/keyspace_notifications/manager"
