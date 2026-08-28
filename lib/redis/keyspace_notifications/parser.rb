# frozen_string_literal: true

class Redis
  module KeyspaceNotifications
    # Binary-safe parsing of keyspace, keyevent and subkey notification messages.
    #
    # Keys and subkeys may contain arbitrary bytes — including the delimiter bytes
    # used by the wire formats (":", "|", ",", "\n") — so parsing never splits keys
    # or subkeys by delimiter: subkey lists are length-prefixed and only the first
    # occurrence of a family's structural delimiter is significant.
    module Parser
      HEADER = /\A__(keyspace|keyevent|subkeyspace|subkeyevent|subkeyspaceitem|subkeyspaceevent)@(\d+|\*)__:/

      COMMA = 0x2C # ","
      PIPE = 0x7C  # "|"

      module_function

      # Parse a pub/sub message received on a notification channel.
      #
      # @param channel [String] the channel the message arrived on
      # @param payload [String] the message payload
      # @param pattern [String, nil] the psubscribe pattern that matched, if any
      # @return [Notification, nil] the parsed notification, or nil when +channel+
      #   is not a notification channel
      # @raise [ParseError] when the channel belongs to a notification family but the
      #   channel suffix or payload is malformed
      def parse(channel, payload, pattern: nil)
        channel = channel.b
        payload = payload.b
        match = HEADER.match(channel)
        return nil unless match

        family = match[1].to_sym
        db = match[2] == "*" ? "*" : match[2].to_i
        rest = channel.byteslice(match[0].bytesize, channel.bytesize)

        event, key, subkeys =
          case family
          when :keyspace then parse_keyspace(rest, payload, channel)
          when :keyevent then parse_keyevent(rest, payload, channel)
          when :subkeyspace then parse_subkeyspace(rest, payload, channel)
          when :subkeyevent then parse_subkeyevent(rest, payload, channel)
          when :subkeyspaceitem then parse_subkeyspaceitem(rest, payload, channel)
          when :subkeyspaceevent then parse_subkeyspaceevent(rest, payload, channel)
          end

        # Redis never emits an empty event name; one here means garbage was
        # published on a notification channel, which must surface as the
        # documented ParseError, not as a Notification violating the contract.
        # (Empty KEYS are legal — "" is a valid Redis key — as are empty subkeys.)
        raise error("empty event name", channel, payload) if event.empty?

        Notification.new(
          family: family,
          db: db,
          event: event,
          key: key,
          subkeys: subkeys,
          channel: channel,
          payload: payload,
          pattern: pattern
        )
      end

      # @api private
      def parse_keyspace(rest, payload, _channel)
        [payload, rest, []]
      end

      # @api private
      def parse_keyevent(rest, payload, _channel)
        [rest, payload, []]
      end

      # @api private
      # Payload: "<event>|<len>:<subkey>[,<len>:<subkey>...]" — events never contain "|",
      # so the first "|" is the delimiter; everything after is length-prefixed.
      def parse_subkeyspace(rest, payload, channel)
        bar = payload.index("|")
        raise error("missing \"|\" between event and subkeys", channel, payload) if bar.nil?

        event = payload.byteslice(0, bar)
        subkeys = parse_subkey_list(payload, bar + 1, channel)
        [event, rest, subkeys]
      end

      # @api private
      # Payload: "<key_len>:<key>|<len>:<subkey>[,...]" — the key is read by length,
      # never by delimiter, because keys may contain "|".
      def parse_subkeyevent(rest, payload, channel)
        key, pos = read_length_prefixed(payload, 0, channel)
        raise error("missing \"|\" after key", channel, payload) unless payload.getbyte(pos) == PIPE

        subkeys = parse_subkey_list(payload, pos + 1, channel)
        [rest, key, subkeys]
      end

      # @api private
      # Channel suffix: "<key>\n<subkey>" — the server only emits this family for keys
      # without "\n", so the first "\n" is the delimiter (the subkey may contain "\n").
      def parse_subkeyspaceitem(rest, payload, channel)
        newline = rest.index("\n")
        raise error("missing \"\\n\" between key and subkey", channel, payload) if newline.nil?

        key = rest.byteslice(0, newline)
        subkey = rest.byteslice(newline + 1, rest.bytesize)
        [payload, key, [subkey]]
      end

      # @api private
      # Channel suffix: "<event>|<key>" — events never contain "|", so the first "|"
      # is the delimiter (the key may contain further "|" bytes).
      def parse_subkeyspaceevent(rest, payload, channel)
        bar = rest.index("|")
        raise error("missing \"|\" between event and key", channel, payload) if bar.nil?

        event = rest.byteslice(0, bar)
        key = rest.byteslice(bar + 1, rest.bytesize)
        subkeys = parse_subkey_list(payload, 0, channel)
        [event, key, subkeys]
      end

      # @api private
      # Reads "<len>:<bytes>" at byte offset +pos+ of +buf+. Returns [value, next_pos].
      # The value is read by length, so its content bytes are inert.
      def read_length_prefixed(buf, pos, channel)
        colon = buf.index(":", pos)
        raise error("missing length prefix at byte #{pos}", channel, buf) if colon.nil? || colon == pos

        len_str = buf.byteslice(pos, colon - pos)
        raise error("invalid length #{len_str.inspect} at byte #{pos}", channel, buf) unless /\A\d+\z/.match?(len_str)

        len = len_str.to_i
        # Bounds-check before byteslice: a length exceeding the remaining bytes is
        # malformed input (and an absurdly large one would otherwise surface as
        # RangeError from byteslice instead of the documented ParseError).
        raise error("truncated value at byte #{colon + 1}", channel, buf) if len > buf.bytesize - (colon + 1)

        [buf.byteslice(colon + 1, len), colon + 1 + len]
      end

      # @api private
      # Reads "<len>:<subkey>[,<len>:<subkey>...]" from +pos+ to the end of +buf+.
      # Returns an ordered Array preserving duplicates. The grammar requires at
      # least one entry — an empty subkey is "0:", never an absent list — so a
      # payload ending right at +pos+ is malformed, not an empty list.
      def parse_subkey_list(buf, pos, channel)
        subkeys = []
        size = buf.bytesize
        raise error("missing subkey list at byte #{pos}", channel, buf) if pos >= size

        loop do
          value, pos = read_length_prefixed(buf, pos, channel)
          subkeys << value
          break if pos == size
          raise error("expected \",\" at byte #{pos}", channel, buf) unless buf.getbyte(pos) == COMMA

          pos += 1
        end
        subkeys
      end

      # @api private
      def error(message, channel, payload)
        ParseError.new("malformed keyspace notification: #{message}", channel: channel, payload: payload)
      end
    end
  end
end
