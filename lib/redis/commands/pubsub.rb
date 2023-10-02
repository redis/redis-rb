# frozen_string_literal: true

class Redis
  module Commands
    module Pubsub
      # Post a message to a channel.
      def publish(channel, message)
        send_command([:publish, channel, message])
      end

      def subscribed?
        !@subscription_client.nil?
      end

      # Listen for messages published to the given channels.
      def subscribe(*channels, &block)
        _subscription(:subscribe, 0, channels, block)
      end

      # Listen for messages published to the given channels. Throw a timeout error
      # if there is no messages for a timeout period.
      def subscribe_with_timeout(timeout, *channels, &block)
        _subscription(:subscribe_with_timeout, timeout, channels, block)
      end

      # Stop listening for messages posted to the given channels.
      def unsubscribe(*channels)
        _subscription(:unsubscribe, 0, channels, nil)
      end

      # Listen for messages published to channels matching the given patterns.
      def psubscribe(*channels, &block)
        _subscription(:psubscribe, 0, channels, block)
      end

      # Listen for messages published to channels matching the given patterns.
      # Throw a timeout error if there is no messages for a timeout period.
      def psubscribe_with_timeout(timeout, *channels, &block)
        _subscription(:psubscribe_with_timeout, timeout, channels, block)
      end

      # Stop listening for messages posted to channels matching the given patterns.
      def punsubscribe(*channels)
        _subscription(:punsubscribe, 0, channels, nil)
      end

      # Inspect the state of the Pub/Sub subsystem.
      # Possible subcommands: channels, numsub, numpat.
      def pubsub(subcommand, *args)
        send_command([:pubsub, subcommand] + args)
      end

      # Post a message to a channel in a shard.
      def spublish(channel, message)
        send_command([:spublish, channel, message])
      end

      # Listen for messages published to the given channels in a shard.
      def ssubscribe(*channels, &block)
        _subscription(:ssubscribe, 0, channels, block)
      end

      # Listen for messages published to the given channels in a shard.
      # Throw a timeout error if there is no messages for a timeout period.
      def ssubscribe_with_timeout(timeout, *channels, &block)
        _subscription(:ssubscribe_with_timeout, timeout, channels, block)
      end

      # Stop listening for messages posted to the given channels in a shard.
      def sunsubscribe(*channels)
        _subscription(:sunsubscribe, 0, channels, nil)
      end
    end
  end
end
