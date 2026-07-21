# frozen_string_literal: true

class Redis
  module Commands
    module Lists
      # Get the length of a list.
      #
      # @param [String] key
      # @return [Integer]
      def llen(key)
        send_command([:llen, key])
      end

      # Remove the first/last element in a list, append/prepend it to another list and return it.
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @param [String, Symbol] where_source from where to remove the element from the source list
      #     e.g. 'LEFT' - from head, 'RIGHT' - from tail
      # @param [String, Symbol] where_destination where to push the element to the source list
      #     e.g. 'LEFT' - to head, 'RIGHT' - to tail
      #
      # @return [nil, String] the element, or nil when the source key does not exist
      #
      # @note This command comes in place of the now deprecated RPOPLPUSH.
      #     Doing LMOVE RIGHT LEFT is equivalent.
      def lmove(source, destination, where_source, where_destination)
        where_source, where_destination = _normalize_move_wheres(where_source, where_destination)

        send_command([:lmove, source, destination, where_source, where_destination])
      end

      # Remove multiple elements from the head/tail of a list, append/prepend
      # them to another list and return them.
      #
      # @example Move a single element (still an array reply)
      #   redis.lmovem("foo", "bar", "LEFT", "LEFT")
      #     # => ["s1"]
      # @example Move up to 3 elements, pushed one-by-one (block order reversed)
      #   redis.lmovem("foo", "bar", "LEFT", "LEFT", count: 3, order: "OBO")
      #     # => ["s3", "s2", "s1"]
      # @example Move exactly 2 elements, preserving their relative order
      #   redis.lmovem("foo", "bar", "LEFT", "RIGHT", exactly: 2, order: "BULK")
      #     # => ["s1", "s2"]
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @param [String, Symbol] where_source from where to remove elements from the source list
      #     e.g. 'LEFT' - from head, 'RIGHT' - from tail
      # @param [String, Symbol] where_destination where to push elements to the destination list
      #     e.g. 'LEFT' - to head, 'RIGHT' - to tail
      # @param [Integer] count move up to `count` elements, fewer when the source holds fewer
      # @param [Integer] exactly move exactly `exactly` elements; when the source holds fewer,
      #     nothing is moved
      # @param [String, Symbol] order ordering at the destination, required together with
      #     `count` or `exactly`:
      #  - when `'OBO'` - push each element as popped, so the moved block order is reversed
      #  - when `'BULK'` - preserve the original relative order of the moved elements
      #
      # @return [nil, Array<String>] the moved elements in destination order, or nil when
      #     nothing was moved
      def lmovem(source, destination, where_source, where_destination, count: nil, exactly: nil, order: nil)
        where_source, where_destination = _normalize_move_wheres(where_source, where_destination)

        args = [:lmovem, source, destination, where_source, where_destination]
        args.concat(_movem_amount_args(count, exactly, order))

        send_command(args)
      end

      # Remove multiple elements from the head/tail of a list, append/prepend
      # them to another list and return them; or block until the request can
      # be satisfied or the timeout expires.
      #
      # @example Move up to 3 elements as soon as any are available
      #   redis.blmovem("foo", "bar", "LEFT", "LEFT", timeout: 1, count: 3, order: "BULK")
      #     # => ["s1", "s2", "s3"]
      # @example Block until the source holds at least 2 elements
      #   redis.blmovem("foo", "bar", "LEFT", "RIGHT", timeout: 1, exactly: 2, order: "OBO")
      #     # => nil on timeout
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @param [String, Symbol] where_source from where to remove elements from the source list
      #     e.g. 'LEFT' - from head, 'RIGHT' - from tail
      # @param [String, Symbol] where_destination where to push elements to the destination list
      #     e.g. 'LEFT' - to head, 'RIGHT' - to tail
      # @param [Float, Integer] timeout seconds to block, 0 blocks indefinitely
      # @param [Integer] count move up to `count` elements as soon as at least one is available
      # @param [Integer] exactly move exactly `exactly` elements, blocking until the source
      #     holds that many
      # @param [String, Symbol] order ordering at the destination, required together with
      #     `count` or `exactly`:
      #  - when `'OBO'` - push each element as popped, so the moved block order is reversed
      #  - when `'BULK'` - preserve the original relative order of the moved elements
      #
      # @return [nil, Array<String>] the moved elements in destination order, or nil when the
      #     timeout expired and nothing was moved
      #
      # @see #lmovem
      def blmovem(source, destination, where_source, where_destination, timeout: 0, count: nil, exactly: nil,
                  order: nil)
        where_source, where_destination = _normalize_move_wheres(where_source, where_destination)

        command = [:blmovem, source, destination, where_source, where_destination, timeout]
        command.concat(_movem_amount_args(count, exactly, order))

        send_blocking_command(command, timeout)
      end

      # Remove the first/last element in a list and append/prepend it
      # to another list and return it, or block until one is available.
      #
      # @example With timeout
      #   element = redis.blmove("foo", "bar", "LEFT", "RIGHT", timeout: 5)
      #     # => nil on timeout
      #     # => "element" on success
      # @example Without timeout
      #   element = redis.blmove("foo", "bar", "LEFT", "RIGHT")
      #     # => "element"
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @param [String, Symbol] where_source from where to remove the element from the source list
      #     e.g. 'LEFT' - from head, 'RIGHT' - from tail
      # @param [String, Symbol] where_destination where to push the element to the source list
      #     e.g. 'LEFT' - to head, 'RIGHT' - to tail
      # @param [Hash] options
      #   - `:timeout => [Float, Integer]`: timeout in seconds, defaults to no timeout
      #
      # @return [nil, String] the element, or nil when the source key does not exist or the timeout expired
      #
      def blmove(source, destination, where_source, where_destination, timeout: 0)
        where_source, where_destination = _normalize_move_wheres(where_source, where_destination)

        command = [:blmove, source, destination, where_source, where_destination, timeout]
        send_blocking_command(command, timeout)
      end

      # Prepend one or more values to a list, creating the list if it doesn't exist
      #
      # @param [String] key
      # @param [String, Array<String>] value string value, or array of string values to push
      # @return [Integer] the length of the list after the push operation
      def lpush(key, value)
        send_command([:lpush, key, value])
      end

      # Prepend a value to a list, only if the list exists.
      #
      # @param [String] key
      # @param [String] value
      # @return [Integer] the length of the list after the push operation
      def lpushx(key, value)
        send_command([:lpushx, key, value])
      end

      # Append one or more values to a list, creating the list if it doesn't exist
      #
      # @param [String] key
      # @param [String, Array<String>] value string value, or array of string values to push
      # @return [Integer] the length of the list after the push operation
      def rpush(key, value)
        send_command([:rpush, key, value])
      end

      # Append a value to a list, only if the list exists.
      #
      # @param [String] key
      # @param [String] value
      # @return [Integer] the length of the list after the push operation
      def rpushx(key, value)
        send_command([:rpushx, key, value])
      end

      # Remove and get the first elements in a list.
      #
      # @param [String] key
      # @param [Integer] count number of elements to remove
      # @return [nil, String, Array<String>] the values of the first elements
      def lpop(key, count = nil)
        command = [:lpop, key]
        command << Integer(count) if count
        send_command(command)
      end

      # Remove and get the last elements in a list.
      #
      # @param [String] key
      # @param [Integer] count number of elements to remove
      # @return [nil, String, Array<String>] the values of the last elements
      def rpop(key, count = nil)
        command = [:rpop, key]
        command << Integer(count) if count
        send_command(command)
      end

      # Remove the last element in a list, append it to another list and return it.
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @return [nil, String] the element, or nil when the source key does not exist
      def rpoplpush(source, destination)
        send_command([:rpoplpush, source, destination])
      end

      # Remove and get the first element in a list, or block until one is available.
      #
      # @example With timeout
      #   list, element = redis.blpop("list", :timeout => 5)
      #     # => nil on timeout
      #     # => ["list", "element"] on success
      # @example Without timeout
      #   list, element = redis.blpop("list")
      #     # => ["list", "element"]
      # @example Blocking pop on multiple lists
      #   list, element = redis.blpop(["list", "another_list"])
      #     # => ["list", "element"]
      #
      # @param [String, Array<String>] keys one or more keys to perform the
      #   blocking pop on
      # @param [Hash] options
      #   - `:timeout => [Float, Integer]`: timeout in seconds, defaults to no timeout
      #
      # @return [nil, [String, String]]
      #   - `nil` when the operation timed out
      #   - tuple of the list that was popped from and element was popped otherwise
      def blpop(*args)
        _bpop(:blpop, args)
      end

      # Remove and get the last element in a list, or block until one is available.
      #
      # @param [String, Array<String>] keys one or more keys to perform the
      #   blocking pop on
      # @param [Hash] options
      #   - `:timeout => [Float, Integer]`: timeout in seconds, defaults to no timeout
      #
      # @return [nil, [String, String]]
      #   - `nil` when the operation timed out
      #   - tuple of the list that was popped from and element was popped otherwise
      #
      # @see #blpop
      def brpop(*args)
        _bpop(:brpop, args)
      end

      # Pop a value from a list, push it to another list and return it; or block
      # until one is available.
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @param [Hash] options
      #   - `:timeout => [Float, Integer]`: timeout in seconds, defaults to no timeout
      #
      # @return [nil, String]
      #   - `nil` when the operation timed out
      #   - the element was popped and pushed otherwise
      def brpoplpush(source, destination, timeout: 0)
        command = [:brpoplpush, source, destination, timeout]
        send_blocking_command(command, timeout)
      end

      # Pops one or more elements from the first non-empty list key from the list
      # of provided key names. If lists are empty, blocks until timeout has passed.
      #
      # @example Popping a element
      #   redis.blmpop(1.0, 'list')
      #   #=> ['list', ['a']]
      # @example With count option
      #   redis.blmpop(1.0, 'list', count: 2)
      #   #=> ['list', ['a', 'b']]
      #
      # @params timeout [Float] a float value specifying the maximum number of seconds to block) elapses.
      #   A timeout of zero can be used to block indefinitely.
      # @params key [String, Array<String>] one or more keys with lists
      # @params modifier [String]
      #  - when `"LEFT"` - the elements popped are those from the left of the list
      #  - when `"RIGHT"` - the elements popped are those from the right of the list
      # @params count [Integer] a number of elements to pop
      #
      # @return [Array<String, Array<String, Float>>] list of popped elements or nil
      def blmpop(timeout, *keys, modifier: "LEFT", count: nil)
        raise ArgumentError, "Pick either LEFT or RIGHT" unless modifier == "LEFT" || modifier == "RIGHT"

        args = [:blmpop, timeout, keys.size, *keys, modifier]
        args << "COUNT" << Integer(count) if count

        send_blocking_command(args, timeout)
      end

      # Pops one or more elements from the first non-empty list key from the list
      # of provided key names.
      #
      # @example Popping a element
      #   redis.lmpop('list')
      #   #=> ['list', ['a']]
      # @example With count option
      #   redis.lmpop('list', count: 2)
      #   #=> ['list', ['a', 'b']]
      #
      # @params key [String, Array<String>] one or more keys with lists
      # @params modifier [String]
      #  - when `"LEFT"` - the elements popped are those from the left of the list
      #  - when `"RIGHT"` - the elements popped are those from the right of the list
      # @params count [Integer] a number of elements to pop
      #
      # @return [Array<String, Array<String, Float>>] list of popped elements or nil
      def lmpop(*keys, modifier: "LEFT", count: nil)
        raise ArgumentError, "Pick either LEFT or RIGHT" unless modifier == "LEFT" || modifier == "RIGHT"

        args = [:lmpop, keys.size, *keys, modifier]
        args << "COUNT" << Integer(count) if count

        send_command(args)
      end

      # Get an element from a list by its index.
      #
      # @param [String] key
      # @param [Integer] index
      # @return [String]
      def lindex(key, index)
        send_command([:lindex, key, Integer(index)])
      end

      # Insert an element before or after another element in a list.
      #
      # @param [String] key
      # @param [String, Symbol] where `BEFORE` or `AFTER`
      # @param [String] pivot reference element
      # @param [String] value
      # @return [Integer] length of the list after the insert operation, or `-1`
      #   when the element `pivot` was not found
      def linsert(key, where, pivot, value)
        send_command([:linsert, key, where, pivot, value])
      end

      # Get a range of elements from a list.
      #
      # @param [String] key
      # @param [Integer] start start index
      # @param [Integer] stop stop index
      # @return [Array<String>]
      def lrange(key, start, stop)
        send_command([:lrange, key, Integer(start), Integer(stop)])
      end

      # Remove elements from a list.
      #
      # @param [String] key
      # @param [Integer] count number of elements to remove. Use a positive
      #   value to remove the first `count` occurrences of `value`. A negative
      #   value to remove the last `count` occurrences of `value`. Or zero, to
      #   remove all occurrences of `value` from the list.
      # @param [String] value
      # @return [Integer] the number of removed elements
      def lrem(key, count, value)
        send_command([:lrem, key, Integer(count), value])
      end

      # Set the value of an element in a list by its index.
      #
      # @param [String] key
      # @param [Integer] index
      # @param [String] value
      # @return [String] `OK`
      def lset(key, index, value)
        send_command([:lset, key, Integer(index), value])
      end

      # Trim a list to the specified range.
      #
      # @param [String] key
      # @param [Integer] start start index
      # @param [Integer] stop stop index
      # @return [String] `OK`
      def ltrim(key, start, stop)
        send_command([:ltrim, key, Integer(start), Integer(stop)])
      end

      private

      def _bpop(cmd, args, &blk)
        timeout = if args.last.is_a?(Hash)
          options = args.pop
          options[:timeout]
        end

        timeout ||= 0
        unless timeout.is_a?(Integer) || timeout.is_a?(Float)
          raise ArgumentError, "timeout must be an Integer or Float, got: #{timeout.class}"
        end

        args.flatten!(1)
        command = [cmd].concat(args)
        command << timeout
        send_blocking_command(command, timeout, &blk)
      end

      def _movem_amount_args(count, exactly, order)
        raise ArgumentError, "Pick either count or exactly, not both" if count && exactly

        if count || exactly
          order = order.to_s.upcase
          raise ArgumentError, "order must be 'OBO' or 'BULK'" if order != "OBO" && order != "BULK"

          [count ? "COUNT" : "EXACTLY", Integer(count || exactly), order]
        elsif order
          raise ArgumentError, "order requires count or exactly"
        else
          []
        end
      end

      def _normalize_move_wheres(where_source, where_destination)
        where_source      = where_source.to_s.upcase
        where_destination = where_destination.to_s.upcase

        if where_source != "LEFT" && where_source != "RIGHT"
          raise ArgumentError, "where_source must be 'LEFT' or 'RIGHT'"
        end

        if where_destination != "LEFT" && where_destination != "RIGHT"
          raise ArgumentError, "where_destination must be 'LEFT' or 'RIGHT'"
        end

        [where_source, where_destination]
      end
    end
  end
end
