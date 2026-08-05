# frozen_string_literal: true

class Redis
  module Commands
    module Arrays
      # Set one or more contiguous values starting at an index in an array.
      #
      # When multiple values are given they are stored at consecutive indices
      # beginning at `index`. Writing past the current end of the array
      # extends it; slots that are skipped over stay empty. Only non-negative
      # indices are valid.
      #
      # @example Set two values at the head of the array
      #   redis.arset("foo", 0, "a", "b")
      #     # => 2
      # @example Overwrite an existing slot (no new slot is filled)
      #   redis.arset("foo", 1, "B")
      #     # => 0
      #
      # @param [String] key
      # @param [Integer] index zero-based index at which to start writing
      # @param [String] values one or more values stored at consecutive
      #   indices beginning at `index`
      # @return [Integer] the number of previously empty slots that were set
      def arset(key, index, *values)
        send_command([:arset, key, Integer(index), *values])
      end

      # Get the value at an index in an array.
      #
      # @example
      #   redis.arget("foo", 0)
      #     # => "a"
      # @example A missing key, an empty slot or an index past the end
      #   redis.arget("foo", 99)
      #     # => nil
      #
      # @param [String] key
      # @param [Integer] index zero-based index of the element to retrieve
      # @return [String, nil] the value at the given index, or `nil` if the
      #   key does not exist or the index holds no value
      def arget(key, index)
        send_command([:arget, key, Integer(index)])
      end

      # Set multiple index-value pairs in an array.
      #
      # Pairs may be non-contiguous and given in any order, as a flat list or
      # a Hash.
      #
      # @example With a flat list of pairs
      #   redis.armset("foo", 0, "a", 5, "f")
      #     # => 2
      # @example With an array (flat, or one array per pair)
      #   redis.armset("foo", [0, "a"], [5, "f"])
      #     # => 2
      # @example With a Hash
      #   redis.armset("foo", { 0 => "a", 5 => "f" })
      #     # => 2
      #
      # @param [String] key
      # @param [Array<Integer, String>, Hash{Integer => String}] pairs index-value pairs
      # @return [Integer] the number of previously empty slots that were set
      def armset(key, *pairs)
        pairs = if pairs.size == 1 && pairs.first.is_a?(Hash)
          pairs.first.flatten
        else
          pairs.flatten(1)
        end
        raise ArgumentError, "wrong number of arguments" if pairs.empty? || pairs.size.odd?

        args = pairs.each_slice(2).flat_map { |index, value| [Integer(index), value] }
        send_command([:armset, key, *args])
      end

      # Get values at multiple indices in an array.
      #
      # The reply preserves the order of the requested indices and contains
      # `nil` for any index that is not set.
      #
      # @example
      #   redis.armget("foo", 0, 1, 9)
      #     # => ["a", "b", nil]
      #
      # @param [String] key
      # @param [Integer] indices one or more zero-based indices
      # @return [Array<String, nil>] the values at the requested indices
      def armget(key, *indices)
        indices = indices.flatten(1).map { |index| Integer(index) }
        send_command([:armget, key, *indices])
      end

      # Get values in a range of indices.
      #
      # Empty slots inside the range are returned as `nil`. When `start` is
      # greater than `stop`, elements are returned in reverse index order.
      #
      # @example
      #   redis.argetrange("foo", 0, 2)
      #     # => ["a", nil, "c"]
      # @example Reverse order
      #   redis.argetrange("foo", 2, 0)
      #     # => ["c", nil, "a"]
      #
      # @param [String] key
      # @param [Integer] start zero-based index of the first element (inclusive)
      # @param [Integer] stop zero-based index of the last element (inclusive)
      # @return [Array<String, nil>] the values in traversal order
      def argetrange(key, start, stop)
        send_command([:argetrange, key, Integer(start), Integer(stop)])
      end

      # Get the length of an array (max index + 1).
      #
      # @param [String] key
      # @return [Integer] the array length, or 0 if the key does not exist
      def arlen(key)
        send_command([:arlen, key])
      end

      # Get the number of non-empty elements in an array.
      #
      # @param [String] key
      # @return [Integer] the number of set elements, or 0 if the key does not exist
      def arcount(key)
        send_command([:arcount, key])
      end

      # Delete elements at the specified indices in an array.
      #
      # Deleting an index that is not set counts as zero elements deleted and
      # does not modify the array.
      #
      # @param [String] key
      # @param [Integer] indices one or more zero-based indices to delete
      # @return [Integer] the number of elements deleted
      def ardel(key, *indices)
        indices = indices.flatten(1).map { |index| Integer(index) }
        send_command([:ardel, key, *indices])
      end

      # Delete elements in one or more inclusive index ranges.
      #
      # Ranges may overlap; each element is counted at most once. A range
      # given with `start > stop` is processed in ascending order regardless.
      #
      # @example Delete two ranges
      #   redis.ardelrange("foo", 0, 2, 5, 7)
      #     # => 6
      # @example Ranges as pairs
      #   redis.ardelrange("foo", [0, 2], [5, 7])
      #     # => 6
      #
      # @param [String] key
      # @param [Array<Integer>] ranges one or more start/stop pairs
      # @return [Integer] the number of elements deleted
      def ardelrange(key, *ranges)
        ranges = ranges.flatten(1).map { |index| Integer(index) }
        raise ArgumentError, "ranges must be given as start/stop pairs" if ranges.empty? || ranges.size.odd?

        send_command([:ardelrange, key, *ranges])
      end

      # Insert one or more values at consecutive indices, beginning at the
      # array's insert cursor. The cursor advances by one for each value.
      #
      # @see #arnext inspect the current cursor position
      # @see #arseek reposition the cursor
      #
      # @param [String] key
      # @param [String] values one or more values to insert
      # @return [Integer] the last index where a value was inserted
      def arinsert(key, *values)
        send_command([:arinsert, key, *values])
      end

      # Set the insert cursor of an array to a specific index.
      #
      # @param [String] key
      # @param [Integer] index zero-based index for the new cursor position
      # @return [Boolean] whether the cursor was set (`false` if the key does not exist)
      def arseek(key, index)
        send_command([:arseek, key, Integer(index)], &Boolify)
      end

      # Get the next index {#arinsert} would use.
      #
      # @param [String] key
      # @return [Integer, nil] the next insert index (0 for missing keys or
      #   before any insert), or `nil` when the insertion cursor is exhausted
      def arnext(key)
        send_command([:arnext, key])
      end

      # Get the most recently inserted elements.
      #
      # @param [String] key
      # @param [Integer] count maximum number of elements to return; if the
      #   array holds fewer elements, all of them are returned
      # @param [Boolean] rev return elements most recent first instead of the
      #   default oldest-first order
      # @return [Array<String>] the most recently inserted elements
      def arlastitems(key, count, rev: false)
        args = [:arlastitems, key, Integer(count)]
        args << "REV" if rev
        send_command(args)
      end

      # Insert one or more values into an array used as a fixed-size ring
      # buffer. Each value is placed at the next position in the ring and the
      # cursor advances, wrapping around to index 0 once the ring is full.
      #
      # @param [String] key
      # @param [Integer] size the size of the ring buffer window
      # @param [String] values one or more values to insert
      # @return [Integer] the last index where a value was inserted
      def arring(key, size, *values)
        send_command([:arring, key, Integer(size), *values])
      end

      # Iterate existing elements in an index range.
      #
      # Empty slots are excluded. When `start` is greater than `stop` the
      # iteration is reversed.
      #
      # @example
      #   redis.arscan("foo", 0, 9)
      #     # => [[0, "a"], [3, "d"]]
      #
      # @param [String] key
      # @param [Integer] start zero-based start index (inclusive)
      # @param [Integer] stop zero-based end index (inclusive)
      # @param [Integer] limit cap on the number of elements returned;
      #   all populated elements in range are returned when omitted
      # @return [Array<Array(Integer, String)>] `[index, value]` pairs in
      #   traversal order; empty when the key does not exist
      def arscan(key, start, stop, limit: nil)
        args = [:arscan, key, Integer(start), Integer(stop)]
        args << "LIMIT" << Integer(limit) if limit
        send_command(args)
      end

      # Search array elements within an inclusive index range using one or
      # more textual predicates. Empty slots are skipped.
      #
      # Each predicate keyword accepts a single value or an array of values;
      # multiple predicates are combined with `logic:` (`:or` by default).
      #
      # @example Substring search
      #   redis.argrep("foo", 0, 9, match: "an")
      #     # => [1, 2]
      # @example Combined predicates with values
      #   redis.argrep("foo", 0, 9, glob: "a*", exact: "cherry", logic: :or, with_values: true)
      #     # => [[0, "apple"], [2, "cherry"]]
      #
      # @param [String] key
      # @param [Integer, String] start zero-based start index (inclusive), or
      #   `"-"` for the start of the array; iteration is reversed when greater
      #   than `stop`
      # @param [Integer, String] stop zero-based end index (inclusive), or
      #   `"+"` for the end of the array
      # @param [String, Array<String>] exact match by exact equality
      # @param [String, Array<String>] match match by substring
      # @param [String, Array<String>] glob match by glob-style pattern (`*`, `?`, `[...]`)
      # @param [String, Array<String>] re match by regular expression
      # @param [Symbol] logic `:and` or `:or` — how multiple predicates combine (server default is OR)
      # @param [Integer] limit stop after this many matches
      # @param [Boolean] with_values return `[index, value]` pairs instead of indices
      # @param [Boolean] nocase case-insensitive comparison for all predicates
      # @return [Array<Integer>, Array<Array(Integer, String)>] matching
      #   indices in traversal order, or `[index, value]` pairs with `with_values`
      def argrep(key, start, stop, exact: nil, match: nil, glob: nil, re: nil,
                 logic: nil, limit: nil, with_values: nil, nocase: nil)
        args = [:argrep, key, argrep_bound(start), argrep_bound(stop)]
        { "EXACT" => exact, "MATCH" => match, "GLOB" => glob, "RE" => re }.each do |predicate, values|
          Array(values).each { |value| args << predicate << value }
        end
        if logic
          operator = logic.to_s.upcase
          raise ArgumentError, "logic must be :and or :or" unless %w[AND OR].include?(operator)

          args << operator
        end
        args << "LIMIT" << Integer(limit) if limit
        args << "WITHVALUES" if with_values
        args << "NOCASE" if nocase
        send_command(args)
      end

      # Perform an aggregate operation on the non-empty elements in a range.
      #
      # Supported operations: `:sum`, `:min`, `:max` (numeric, returned as
      # Float), `:and`, `:or`, `:xor` (bitwise, floats truncated toward
      # zero), `:match` (count of elements equal to `value`) and `:used`
      # (count of non-empty elements).
      #
      # @example
      #   redis.arop("foo", 0, 9, :sum)
      #     # => 6.0
      # @example Count elements equal to a value
      #   redis.arop("foo", 0, 9, :match, value: "2")
      #     # => 1
      #
      # @param [String] key
      # @param [Integer] start zero-based index of the first element (inclusive);
      #   the range is always scanned from the lower to the higher index
      # @param [Integer] stop zero-based index of the last element (inclusive)
      # @param [Symbol, String] operation one of `:sum`, `:min`, `:max`,
      #   `:and`, `:or`, `:xor`, `:match`, `:used`
      # @param [String] value the value to compare against (required for `:match`)
      # @return [Float, Integer, nil] the aggregate result — a Float for
      #   `:sum`/`:min`/`:max`, an Integer otherwise; `nil` when no elements
      #   qualify
      def arop(key, start, stop, operation, value: nil)
        operation = operation.to_s.upcase
        args = [:arop, key, Integer(start), Integer(stop), operation]
        args << value if operation == "MATCH"

        if %w[SUM MIN MAX].include?(operation)
          send_command(args, &Floatify)
        else
          send_command(args)
        end
      end

      # Get metadata about an array.
      #
      # @param [String] key
      # @param [Boolean] full include per-slice statistics
      # @return [Hash{String => Integer, Float}] metadata fields such as
      #   `count`, `len`, `next-insert-index` and `slices`; with `full:` the
      #   `avg-*` slice statistics are returned as `Float`
      # @raise [Redis::CommandError] when the key does not exist
      def arinfo(key, full: false)
        args = [:arinfo, key]
        args << "FULL" if full
        send_command(args, &HashifyArrayInfo)
      end

      private

      # ARGREP accepts "-" / "+" as full-range bounds — unlike the other AR*
      # range commands, which take numeric indices only (verified on Redis
      # 8.8). Anything else is coerced so typos still fail fast client-side.
      def argrep_bound(index)
        index == "-" || index == "+" ? index : Integer(index)
      end
    end
  end
end
