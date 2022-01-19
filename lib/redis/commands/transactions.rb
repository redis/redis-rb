# frozen_string_literal: true

class Redis
  module Commands
    module Transactions
      # Execute all commands issued after MULTI.
      #
      # Only call this method when `#multi` was called **without** a block.
      #
      # @return [nil, Array<...>]
      #   - when commands were not executed, `nil`
      #   - when commands were executed, an array with their replies
      #
      # @see #multi
      # @see #discard
      def exec
        send_command([:exec])
      end

      # Discard all commands issued after MULTI.
      #
      # Only call this method when `#multi` was called **without** a block.
      #
      # @return [String] `"OK"`
      #
      # @see #multi
      # @see #exec
      def discard
        send_command([:discard])
      end
    end
  end
end
