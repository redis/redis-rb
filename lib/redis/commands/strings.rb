# frozen_string_literal: true

class Redis
  module Commands
    module Strings
      # Decrement the integer value of a key by one.
      #
      # @example
      #   redis.decr("value")
      #     # => 4
      #
      # @param [String] key
      # @return [Integer] value after decrementing it
      def decr(key)
        send_command([:decr, key])
      end

      # Decrement the integer value of a key by the given number.
      #
      # @example
      #   redis.decrby("value", 5)
      #     # => 0
      #
      # @param [String] key
      # @param [Integer] decrement
      # @return [Integer] value after decrementing it
      def decrby(key, decrement)
        send_command([:decrby, key, Integer(decrement)])
      end

      # Increment the integer value of a key by one.
      #
      # @example
      #   redis.incr("value")
      #     # => 6
      #
      # @param [String] key
      # @return [Integer] value after incrementing it
      def incr(key)
        send_command([:incr, key])
      end

      # Increment the integer value of a key by the given integer number.
      #
      # @example
      #   redis.incrby("value", 5)
      #     # => 10
      #
      # @param [String] key
      # @param [Integer] increment
      # @return [Integer] value after incrementing it
      def incrby(key, increment)
        send_command([:incrby, key, Integer(increment)])
      end

      # Increment the numeric value of a key by the given float number.
      #
      # @example
      #   redis.incrbyfloat("value", 1.23)
      #     # => 1.23
      #
      # @param [String] key
      # @param [Float] increment
      # @return [Float] value after incrementing it
      def incrbyfloat(key, increment)
        send_command([:incrbyfloat, key, Float(increment)], &Floatify)
      end

      # Increment the numeric value of a key atomically, with optional bounds
      # and expiration control. Uses 0 as the initial value if the key does
      # not exist.
      #
      # Unlike `incr`/`incrby`, the reply is a two-element array of the new
      # value and the increment that was actually applied. When the result
      # would fall outside `lbound:`/`ubound:` (or the type limits) the
      # operation is skipped and the reply is `[current_value, 0]`; with
      # `saturate: true` the result is capped at the bound instead and the
      # second element reflects the saturated delta.
      #
      # @example Increment by 1 (integer mode default)
      #   redis.increx("counter")
      #     # => [1, 1]
      # @example Window counter rate limiter: cap at 100, TTL only on window creation
      #   value, applied = redis.increx("ratelimit:#{user_id}", by: 1, ubound: 100, ex: 60, enx: true)
      #   reject_request if applied == 0
      # @example Float mode — selected by the Ruby type of `by:`
      #   redis.increx("temp", by: 0.25)
      #     # => [1.75, 0.25]
      #
      # @param [String] key
      # @param [Integer, Float] by the increment (may be negative). The Ruby
      #   type selects the mode: an `Integer` is sent as `BYINT` (requires an
      #   integer-typed stored value, replies with Integers), a `Float` as
      #   `BYFLOAT` (stored value may be integer or float, replies with
      #   Floats) — so `by: 5` and `by: 5.0` behave differently. Other types
      #   raise `TypeError`. Without `by:`, increments by 1 in integer mode.
      # @param [Integer, Float] lbound lower bound for the result. In float
      #   mode any numeric is accepted; in integer mode it must be an
      #   `Integer` (a `Float` raises `TypeError` rather than silently
      #   truncating, since bounds decide whether the increment applies)
      # @param [Integer, Float] ubound upper bound for the result, with the
      #   same typing rules as `lbound`
      # @param [Boolean] saturate cap/floor an out-of-bounds result at the
      #   bound instead of skipping the operation
      # @param [Integer] ex expiration in seconds
      # @param [Integer] px expiration in milliseconds
      # @param [Integer] exat expiration as a Unix timestamp in seconds
      # @param [Integer] pxat expiration as a Unix timestamp in milliseconds
      # @param [Boolean] persist remove the key's expiration
      # @param [Boolean] enx only set the expiration when the key has no TTL
      #   (the increment is applied regardless); requires one of
      #   `ex`/`px`/`exat`/`pxat`
      # @return [Array(Integer, Integer), Array(Float, Float)]
      #   `[new_value, applied_increment]` — Integers in integer mode, Floats
      #   in float mode (under RESP2 and RESP3 alike); `applied_increment`
      #   is 0 when the operation was skipped as out of bounds
      def increx(key, by: nil, lbound: nil, ubound: nil, saturate: nil,
                 ex: nil, px: nil, exat: nil, pxat: nil, persist: nil, enx: nil)
        if [ex, px, exat, pxat, persist].count { |option| option } > 1
          raise ArgumentError, "ex, px, exat, pxat and persist are mutually exclusive"
        end
        raise ArgumentError, "enx is incompatible with persist" if enx && persist
        raise ArgumentError, "enx requires one of ex, px, exat or pxat" if enx && !(ex || px || exat || pxat)

        # The Ruby type of `by` selects the wire mode; anything else would
        # have to silently pick a mode, so it is rejected instead.
        float_mode = case by
        when nil, Integer then false
        when Float then true
        else raise TypeError, "by must be an Integer (BYINT) or a Float (BYFLOAT), got #{by.class}"
        end

        args = [:increx, key]
        args << (float_mode ? "BYFLOAT" : "BYINT") << by if by
        args << "LBOUND" << increx_bound(:lbound, lbound, float_mode) if lbound
        args << "UBOUND" << increx_bound(:ubound, ubound, float_mode) if ubound
        args << "SATURATE" if saturate
        args << "EX" << Integer(ex) if ex
        args << "PX" << Integer(px) if px
        args << "EXAT" << Integer(exat) if exat
        args << "PXAT" << Integer(pxat) if pxat
        args << "PERSIST" if persist
        args << "ENX" if enx

        if float_mode
          # RESP2 replies with bulk strings, RESP3 with native doubles;
          # converge both on Float.
          send_command(args) { |reply| reply.is_a?(Array) ? reply.map(&Floatify) : reply }
        else
          send_command(args)
        end
      end

      # Set the string value of a key.
      #
      # @param [String] key
      # @param [String] value
      # @param [Hash] options
      #   - `:ex => Integer`: Set the specified expire time, in seconds.
      #   - `:px => Integer`: Set the specified expire time, in milliseconds.
      #   - `:exat => Integer` : Set the specified Unix time at which the key will expire, in seconds.
      #   - `:pxat => Integer` : Set the specified Unix time at which the key will expire, in milliseconds.
      #   - `:nx => true`: Only set the key if it does not already exist.
      #   - `:xx => true`: Only set the key if it already exist.
      #   - `:keepttl => true`: Retain the time to live associated with the key.
      #   - `:get => true`: Return the old string stored at key, or nil if key did not exist.
      # @return [String, Boolean] `"OK"` or true, false if `:nx => true` or `:xx => true`
      def set(key, value, ex: nil, px: nil, exat: nil, pxat: nil, nx: nil, xx: nil, keepttl: nil, get: nil)
        args = [:set, key, value.to_s]
        args << "EX" << Integer(ex) if ex
        args << "PX" << Integer(px) if px
        args << "EXAT" << Integer(exat) if exat
        args << "PXAT" << Integer(pxat) if pxat
        args << "NX" if nx
        args << "XX" if xx
        args << "KEEPTTL" if keepttl
        args << "GET" if get

        if nx || xx
          send_command(args, &BoolifySet)
        else
          send_command(args)
        end
      end

      # Set the time to live in seconds of a key.
      #
      # @param [String] key
      # @param [Integer] ttl
      # @param [String] value
      # @return [String] `"OK"`
      def setex(key, ttl, value)
        send_command([:setex, key, Integer(ttl), value.to_s])
      end

      # Set the time to live in milliseconds of a key.
      #
      # @param [String] key
      # @param [Integer] ttl
      # @param [String] value
      # @return [String] `"OK"`
      def psetex(key, ttl, value)
        send_command([:psetex, key, Integer(ttl), value.to_s])
      end

      # Set the value of a key, only if the key does not exist.
      #
      # @param [String] key
      # @param [String] value
      # @return [Boolean] whether the key was set or not
      def setnx(key, value)
        send_command([:setnx, key, value.to_s], &Boolify)
      end

      # Set one or more values.
      #
      # @example
      #   redis.mset("key1", "v1", "key2", "v2")
      #     # => "OK"
      #
      # @param [Array<String>] args array of keys and values
      # @return [String] `"OK"`
      #
      # @see #mapped_mset
      def mset(*args)
        send_command([:mset] + args)
      end

      # Set one or more values.
      #
      # @example
      #   redis.mapped_mset({ "f1" => "v1", "f2" => "v2" })
      #     # => "OK"
      #
      # @param [Hash] hash keys mapping to values
      # @return [String] `"OK"`
      #
      # @see #mset
      def mapped_mset(hash)
        mset(hash.flatten)
      end

      # Set one or more values, only if none of the keys exist.
      #
      # @example
      #   redis.msetnx("key1", "v1", "key2", "v2")
      #     # => true
      #
      # @param [Array<String>] args array of keys and values
      # @return [Boolean] whether or not all values were set
      #
      # @see #mapped_msetnx
      def msetnx(*args)
        send_command([:msetnx, *args], &Boolify)
      end

      # Set one or more values, only if none of the keys exist.
      #
      # @example
      #   redis.mapped_msetnx({ "key1" => "v1", "key2" => "v2" })
      #     # => true
      #
      # @param [Hash] hash keys mapping to values
      # @return [Boolean] whether or not all values were set
      #
      # @see #msetnx
      def mapped_msetnx(hash)
        msetnx(hash.flatten)
      end

      # Get the value of a key.
      #
      # @param [String] key
      # @return [String]
      def get(key)
        send_command([:get, key])
      end

      # Get the values of all the given keys.
      #
      # @example
      #   redis.mget("key1", "key2")
      #     # => ["v1", "v2"]
      #
      # @param [Array<String>] keys
      # @return [Array<String>] an array of values for the specified keys
      #
      # @see #mapped_mget
      def mget(*keys, &blk)
        keys.flatten!(1)
        send_command([:mget, *keys], &blk)
      end

      # Get the values of all the given keys.
      #
      # @example
      #   redis.mapped_mget("key1", "key2")
      #     # => { "key1" => "v1", "key2" => "v2" }
      #
      # @param [Array<String>] keys array of keys
      # @return [Hash] a hash mapping the specified keys to their values
      #
      # @see #mget
      def mapped_mget(*keys)
        mget(*keys) do |reply|
          if reply.is_a?(Array)
            Hash[keys.zip(reply)]
          else
            reply
          end
        end
      end

      # Overwrite part of a string at key starting at the specified offset.
      #
      # @param [String] key
      # @param [Integer] offset byte offset
      # @param [String] value
      # @return [Integer] length of the string after it was modified
      def setrange(key, offset, value)
        send_command([:setrange, key, Integer(offset), value.to_s])
      end

      # Get a substring of the string stored at a key.
      #
      # @param [String] key
      # @param [Integer] start zero-based start offset
      # @param [Integer] stop zero-based end offset. Use -1 for representing
      #   the end of the string
      # @return [Integer] `0` or `1`
      def getrange(key, start, stop)
        send_command([:getrange, key, Integer(start), Integer(stop)])
      end

      # Append a value to a key.
      #
      # @param [String] key
      # @param [String] value value to append
      # @return [Integer] length of the string after appending
      def append(key, value)
        send_command([:append, key, value])
      end

      # Set the string value of a key and return its old value.
      #
      # @param [String] key
      # @param [String] value value to replace the current value with
      # @return [String] the old value stored in the key, or `nil` if the key
      #   did not exist
      def getset(key, value)
        send_command([:getset, key, value.to_s])
      end

      # Get the value of key and delete the key. This command is similar to GET,
      # except for the fact that it also deletes the key on success.
      #
      # @param [String] key
      # @return [String] the old value stored in the key, or `nil` if the key
      #   did not exist
      def getdel(key)
        send_command([:getdel, key])
      end

      # Get the value of key and optionally set its expiration. GETEX is similar to
      # GET, but is a write command with additional options. When no options are
      # provided, GETEX behaves like GET.
      #
      # @param [String] key
      # @param [Hash] options
      #   - `:ex => Integer`: Set the specified expire time, in seconds.
      #   - `:px => Integer`: Set the specified expire time, in milliseconds.
      #   - `:exat => true`: Set the specified Unix time at which the key will
      #      expire, in seconds.
      #   - `:pxat => true`: Set the specified Unix time at which the key will
      #      expire, in milliseconds.
      #   - `:persist => true`: Remove the time to live associated with the key.
      # @return [String] The value of key, or nil when key does not exist.
      def getex(key, ex: nil, px: nil, exat: nil, pxat: nil, persist: false)
        args = [:getex, key]
        args << "EX" << Integer(ex) if ex
        args << "PX" << Integer(px) if px
        args << "EXAT" << Integer(exat) if exat
        args << "PXAT" << Integer(pxat) if pxat
        args << "PERSIST" if persist

        send_command(args)
      end

      # Get the length of the value stored in a key.
      #
      # @param [String] key
      # @return [Integer] the length of the value stored in the key, or 0
      #   if the key does not exist
      def strlen(key)
        send_command([:strlen, key])
      end

      private

      # INCREX bounds decide whether the increment is applied at all, so a
      # Float bound in integer mode must raise rather than silently truncate
      # (`Integer(2.9)` => 2) — mirroring how `by:` selects the mode strictly.
      def increx_bound(name, value, float_mode)
        return Float(value) if float_mode
        raise TypeError, "#{name} must be an Integer in integer mode, got #{value.class}" unless value.is_a?(Integer)

        value
      end
    end
  end
end
