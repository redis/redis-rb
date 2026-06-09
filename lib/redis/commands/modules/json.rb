# frozen_string_literal: true

require "json"

class Redis
  module Commands
    # Commands for the RedisJSON module (built into Redis core since 8.0, or available
    # earlier through the RedisJSON module in Redis Stack).
    #
    # Values are serialized to JSON text on the client before they are sent, and replies
    # that carry JSON text are parsed back into Ruby objects. The serialized form of these
    # replies is identical under RESP2 and RESP3 (RESP3 has no native JSON type), so the
    # handling here is protocol-independent. Note that some other RedisJSON commands — e.g.
    # JSON.NUMINCRBY — DO return differently shaped replies under RESP3 and will need
    # protocol-aware reshaping once RESP3 is supported at this layer.
    module Json
      # Normalize a JSON.NUMINCRBY reply to a protocol-independent value: an array of numbers for
      # a JSONPath, a single number for a legacy path. Under RESP2 the result arrives as a
      # JSON-encoded string ("[3,4]" / "3"); under RESP3 it arrives as native numbers (an array,
      # even for a legacy path). Both shapes map to the same value.
      NumincrbyNormalize = lambda do |reply, jsonpath|
        return nil if reply.nil?

        reply = ::JSON.parse(reply) if reply.is_a?(String) # RESP2 string form
        if jsonpath
          Array(reply)
        elsif reply.is_a?(Array)
          reply.first # RESP3 wraps even a legacy reply in an array
        else
          reply
        end
      end

      # Normalize a JSON.TYPE reply to a protocol-independent value: an array of type strings for
      # a JSONPath, a single type string for a legacy path. RESP2 returns ["integer"] / "integer";
      # RESP3 nests one level further as [["integer"]] / ["integer"]. Both map to the same value.
      TypeNormalize = lambda do |reply, jsonpath|
        return nil if reply.nil?

        if jsonpath
          reply.flatten # RESP2 ["integer"] stays flat; RESP3 [["integer"]] collapses
        elsif reply.is_a?(Array)
          reply.first # RESP3 legacy ["integer"] -> "integer"
        else
          reply # RESP2 legacy "integer"
        end
      end

      # Set the JSON value at +path+ in the document stored under +key+.
      #
      # By default +value+ is a Ruby object that is serialized to JSON text with
      # JSON.generate. Pass +raw: true+ to send an already-encoded JSON string through
      # untouched (no re-serialization), which avoids double-encoding pre-built JSON.
      #
      # @example
      #   redis.json_set("doc", "$", { "a" => 1, "nested" => { "b" => 2 } })
      #     # => "OK"
      #
      # @example pre-encoded JSON
      #   redis.json_set("doc", "$", '{"a":1}', raw: true)
      #     # => "OK"
      #
      # @example conditional set with NX/XX returns a boolean
      #   redis.json_set("doc", "$.a", 2, nx: true)
      #     # => false
      #
      # @param [String] key
      # @param [String] path a JSONPath, e.g. "$" for the document root
      # @param [Object] value a JSON-serializable Ruby object, or a pre-encoded JSON string
      #   when +raw+ is true
      # @param [Boolean] nx only set when the path does not already exist
      # @param [Boolean] xx only set when the path already exists
      # @param [Boolean] raw treat +value+ as an already-encoded JSON string and send it as-is
      # @return [Boolean, String] when +nx+ or +xx+ is given, +true+ on success and +false+
      #   when the condition was not met; otherwise the raw +"OK"+ reply
      # @raise [ArgumentError] if both +nx+ and +xx+ are given (they are mutually exclusive)
      def json_set(key, path, value, nx: false, xx: false, raw: false)
        raise ArgumentError, "nx and xx are mutually exclusive" if nx && xx

        value = ::JSON.generate(value) unless raw
        args = [:"JSON.SET", key, path, value]
        args << "NX" if nx
        args << "XX" if xx

        if nx || xx
          send_command(args, &BoolifySet)
        else
          send_command(args)
        end
      end

      # Get the JSON value(s) at one or more +paths+ in the document stored under +key+.
      #
      # By default the reply is parsed from JSON text into a Ruby object. Pass +raw: true+ to
      # get the unparsed JSON string back instead (no JSON.parse).
      #
      # @example
      #   redis.json_get("doc")
      #     # => { "a" => 1, "nested" => { "b" => 2 } }
      #
      # @example raw JSON string
      #   redis.json_get("doc", raw: true)
      #     # => '{"a":1,"nested":{"b":2}}'
      #
      # @param [String] key
      # @param [Array<String>] paths zero or more JSONPath expressions; with none the whole
      #   document is returned
      # @param [Boolean] raw return the unparsed JSON string instead of a parsed Ruby object
      # @return [Object, String, nil] the parsed JSON value (or the raw JSON string when +raw+
      #   is true), or nil if the key does not exist
      def json_get(key, *paths, raw: false)
        send_command([:"JSON.GET", key, *paths]) do |reply|
          if reply.nil? || raw
            reply
          else
            ::JSON.parse(reply)
          end
        end
      end

      # Set one or more JSON values atomically, one per +key+/+path+/+value+ triplet. Either all
      # of the writes are applied or none are. For a key that does not yet exist the +path+ must
      # be the root ("$").
      #
      # By default each value is a Ruby object serialized with JSON.generate; pass +raw: true+ to
      # send already-encoded JSON strings through untouched.
      #
      # @example
      #   redis.json_mset("doc1", "$", { "a" => 1 }, "doc2", "$", { "b" => 2 })
      #     # => "OK"
      #
      # @param [Array] args a flat list of key, path, value triplets
      # @param [Boolean] raw treat each value as an already-encoded JSON string
      # @return [String] the raw "OK" reply
      # @raise [ArgumentError] unless +args+ is a non-empty list of complete triplets
      def json_mset(*args, raw: false)
        raise ArgumentError, "wrong number of arguments (expected key/path/value triplets)" \
          if args.empty? || !(args.size % 3).zero?

        command = [:"JSON.MSET"]
        args.each_slice(3) do |key, path, value|
          command << key << path << (raw ? value : ::JSON.generate(value))
        end
        send_command(command)
      end

      # Get the values at a single +path+ from one or more +keys+.
      #
      # Returns one element per key, in order, parsed from JSON text into a Ruby object (or nil
      # when the key or path does not exist). Pass +raw: true+ to get the unparsed JSON strings.
      #
      # @example
      #   redis.json_mget("doc1", "doc2", "$.a")
      #     # => [[1], [2]]
      #
      # @param [Array<String>] keys one or more keys to read
      # @param [String] path a single JSONPath applied to every key
      # @param [Boolean] raw return the unparsed JSON strings instead of parsed Ruby objects
      # @return [Array] one value per key (nil for a missing key/path)
      def json_mget(*keys, path, raw: false)
        keys.flatten!(1)
        send_command([:"JSON.MGET", *keys, path]) do |reply|
          if reply.nil?
            reply
          else
            reply.map { |value| value.nil? || raw ? value : ::JSON.parse(value) }
          end
        end
      end

      # Delete the value(s) at +path+ in the document stored under +key+. When +path+ is omitted
      # it defaults to the root, so deleting the root removes the whole key.
      #
      # @example
      #   redis.json_del("doc", "$.a")
      #     # => 1
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root "$")
      # @return [Integer] the number of values deleted
      def json_del(key, path = nil)
        args = [:"JSON.DEL", key]
        args << path if path
        send_command(args)
      end

      # Delete the value(s) at +path+ in the document stored under +key+. Alias of {#json_del}.
      #
      # @example
      #   redis.json_forget("doc", "$.a")
      #     # => 1
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root "$")
      # @return [Integer] the number of values deleted
      def json_forget(key, path = nil)
        args = [:"JSON.FORGET", key]
        args << path if path
        send_command(args)
      end

      # Clear the container and numeric value(s) at +path+: arrays and objects are emptied and
      # numbers are set to 0. Strings, booleans and null are left unchanged. When +path+ is
      # omitted it defaults to the root.
      #
      # @example
      #   redis.json_clear("doc", "$.arr")
      #     # => 1
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root "$")
      # @return [Integer] the number of values cleared
      def json_clear(key, path = nil)
        args = [:"JSON.CLEAR", key]
        args << path if path
        send_command(args)
      end

      # Merge +value+ into the document stored under +key+ at +path+, following RFC 7396 (JSON
      # Merge Patch): a null value deletes a key, a non-null value creates or updates it, and any
      # value merged into an existing array replaces the whole array. For a key that does not yet
      # exist the +path+ must be the root ("$").
      #
      # By default +value+ is a Ruby object serialized with JSON.generate; pass +raw: true+ to
      # send an already-encoded JSON string through untouched.
      #
      # @example
      #   redis.json_merge("doc", "$.b", 8)
      #     # => "OK"
      #
      # @param [String] key
      # @param [String] path a JSONPath (must be "$" when creating a new key)
      # @param [Object] value a JSON-serializable Ruby object, or a pre-encoded JSON string when
      #   +raw+ is true
      # @param [Boolean] raw treat +value+ as an already-encoded JSON string and send it as-is
      # @return [String] the raw "OK" reply
      def json_merge(key, path, value, raw: false)
        value = ::JSON.generate(value) unless raw
        send_command([:"JSON.MERGE", key, path, value])
      end

      # Append one or more values to the array at +path+ in the document stored under +key+.
      #
      # By default each value is a Ruby object serialized with JSON.generate; pass +raw: true+ to
      # send already-encoded JSON strings through untouched.
      #
      # @example
      #   redis.json_arrappend("doc", "$.colors", "blue")
      #     # => [3]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the target array
      # @param [Array<Object>] values one or more JSON values to append
      # @param [Boolean] raw treat each value as an already-encoded JSON string
      # @return [Array<Integer>, Integer] the new array length(s); an Array for a JSONPath,
      #   a single Integer for a legacy path (nil for a match that is not an array)
      def json_arrappend(key, path, *values, raw: false)
        values = values.map { |value| ::JSON.generate(value) } unless raw
        send_command([:"JSON.ARRAPPEND", key, path, *values])
      end

      # Return the index of the first occurrence of a scalar +value+ in the array at +path+. The
      # optional +start+ (inclusive) and +stop+ (exclusive) bound the search.
      #
      # @example
      #   redis.json_arrindex("doc", "$.colors", "silver")
      #     # => [1]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the target array
      # @param [Object] value the scalar JSON value to search for
      # @param [Integer] start optional inclusive start index
      # @param [Integer] stop optional exclusive stop index
      # @param [Boolean] raw treat +value+ as an already-encoded JSON string
      # @return [Array<Integer>, Integer] the index/indices of the first match (-1 if not found)
      def json_arrindex(key, path, value, start: nil, stop: nil, raw: false)
        value = ::JSON.generate(value) unless raw
        args = [:"JSON.ARRINDEX", key, path, value]
        unless start.nil? && stop.nil?
          args << Integer(start || 0)
          args << Integer(stop) unless stop.nil?
        end
        send_command(args)
      end

      # Insert one or more values into the array at +path+ before +index+ (existing elements at
      # and after +index+ shift right; 0 prepends, negative counts from the end).
      #
      # By default each value is a Ruby object serialized with JSON.generate; pass +raw: true+ to
      # send already-encoded JSON strings through untouched.
      #
      # @example
      #   redis.json_arrinsert("doc", "$.colors", 1, "gold")
      #     # => [4]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the target array
      # @param [Integer] index the position to insert before
      # @param [Array<Object>] values one or more JSON values to insert
      # @param [Boolean] raw treat each value as an already-encoded JSON string
      # @return [Array<Integer>, Integer] the new array length(s)
      def json_arrinsert(key, path, index, *values, raw: false)
        values = values.map { |value| ::JSON.generate(value) } unless raw
        send_command([:"JSON.ARRINSERT", key, path, Integer(index), *values])
      end

      # Return the length of the array at +path+. When +path+ is omitted it defaults to the root.
      #
      # @example
      #   redis.json_arrlen("doc", "$.colors")
      #     # => [2]
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root "$")
      # @return [Array<Integer>, Integer, nil] the array length(s); nil for a match that is not an
      #   array, or when the key/path does not exist
      def json_arrlen(key, path = nil)
        args = [:"JSON.ARRLEN", key]
        args << path if path
        send_command(args)
      end

      # Remove and return an element from the array at +path+. When +path+ is omitted it defaults
      # to the root; when +index+ is omitted it defaults to -1 (the last element).
      #
      # The popped element is returned as parsed JSON (a Ruby object), or as the unparsed JSON
      # string when +raw: true+.
      #
      # @example
      #   redis.json_arrpop("doc", "$.colors", 0)
      #     # => ["black"]
      #
      # @param [String] key
      # @param [String] path an optional JSONPath to the target array (defaults to the root "$")
      # @param [Integer] index an optional position to pop from (defaults to -1, the last element)
      # @param [Boolean] raw return the unparsed JSON string(s) instead of parsed Ruby objects
      # @return [Array, Object, nil] the popped value(s); an Array for a JSONPath, a single value
      #   for a legacy path, nil for an empty array or a non-array match
      # @raise [ArgumentError] if +index+ is given without a +path+
      def json_arrpop(key, path = nil, index = nil, raw: false)
        raise ArgumentError, "index requires a path" if !index.nil? && path.nil?

        args = [:"JSON.ARRPOP", key]
        if path
          args << path
          args << Integer(index) unless index.nil?
        end

        send_command(args) do |reply|
          if reply.nil? || raw
            reply
          elsif reply.is_a?(Array)
            reply.map { |value| value.nil? ? nil : ::JSON.parse(value) }
          else
            ::JSON.parse(reply)
          end
        end
      end

      # Trim the array at +path+ so it keeps only the inclusive range of elements from +start+ to
      # +stop+ (negative indices count from the end).
      #
      # @example
      #   redis.json_arrtrim("doc", "$.colors", 0, 1)
      #     # => [2]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the target array
      # @param [Integer] start inclusive index of the first element to keep
      # @param [Integer] stop inclusive index of the last element to keep
      # @return [Array<Integer>, Integer] the new array length(s)
      def json_arrtrim(key, path, start, stop)
        send_command([:"JSON.ARRTRIM", key, path, Integer(start), Integer(stop)])
      end

      # Increment the numeric value(s) at +path+ in the document stored under +key+ by +number+.
      #
      # @example
      #   redis.json_numincrby("doc", "$.a", 2)
      #     # => [3]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the numeric value(s)
      # @param [Numeric] number the amount to add
      # @return [Array<Numeric>, Numeric, nil] the new value(s): an Array for a JSONPath, a single
      #   number for a legacy path; nil (or nil element) for a non-numeric match
      def json_numincrby(key, path, number)
        jsonpath = json_path?(path)
        send_command([:"JSON.NUMINCRBY", key, path, number]) do |reply|
          NumincrbyNormalize.call(reply, jsonpath)
        end
      end

      # Return the type name of the value(s) at +path+ (e.g. "integer", "string", "object"). When
      # +path+ is omitted it defaults to the root.
      #
      # @example
      #   redis.json_type("doc", "$.a")
      #     # => ["integer"]
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root)
      # @return [Array<String>, String, nil] the type name(s): an Array for a JSONPath, a single
      #   string for a legacy path
      def json_type(key, path = nil)
        jsonpath = json_path?(path)
        args = [:"JSON.TYPE", key]
        args << path if path
        send_command(args) do |reply|
          TypeNormalize.call(reply, jsonpath)
        end
      end

      # Return the key names of the JSON object(s) at +path+. When +path+ is omitted it defaults
      # to the root.
      #
      # @example
      #   redis.json_objkeys("doc", "$.nested")
      #     # => [["b", "c"]]
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root)
      # @return [Array] an array of key-name arrays (JSONPath) or a single array of key names
      #   (legacy path); nil for a non-object match
      def json_objkeys(key, path = nil)
        args = [:"JSON.OBJKEYS", key]
        args << path if path
        send_command(args)
      end

      # Return the number of keys in the JSON object(s) at +path+. When +path+ is omitted it
      # defaults to the root.
      #
      # @example
      #   redis.json_objlen("doc", "$.nested")
      #     # => [2]
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root)
      # @return [Array<Integer>, Integer, nil] the key count(s): an Array for a JSONPath, a single
      #   integer for a legacy path; nil for a non-object match
      def json_objlen(key, path = nil)
        args = [:"JSON.OBJLEN", key]
        args << path if path
        send_command(args)
      end

      # Return the length of the JSON string(s) at +path+. When +path+ is omitted it defaults to
      # the root.
      #
      # @example
      #   redis.json_strlen("doc", "$.a")
      #     # => [3]
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root)
      # @return [Array<Integer>, Integer, nil] the string length(s): an Array for a JSONPath, a
      #   single integer for a legacy path; nil for a non-string match
      def json_strlen(key, path = nil)
        args = [:"JSON.STRLEN", key]
        args << path if path
        send_command(args)
      end

      # Append +value+ to the JSON string(s) at +path+ in the document stored under +key+.
      #
      # By default +value+ is a Ruby string serialized with JSON.generate; pass +raw: true+ to
      # send an already-encoded JSON string through untouched.
      #
      # @example
      #   redis.json_strappend("doc", "$.a", "bar")
      #     # => [6]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the target string(s)
      # @param [String] value the string to append
      # @param [Boolean] raw treat +value+ as an already-encoded JSON string and send it as-is
      # @return [Array<Integer>, Integer, nil] the new string length(s): an Array for a JSONPath, a
      #   single integer for a legacy path; nil for a non-string match
      def json_strappend(key, path, value, raw: false)
        value = ::JSON.generate(value) unless raw
        send_command([:"JSON.STRAPPEND", key, path, value])
      end

      # Toggle the boolean value(s) at +path+ in the document stored under +key+.
      #
      # @example
      #   redis.json_toggle("doc", "$.flag")
      #     # => [0]
      #
      # @param [String] key
      # @param [String] path a JSONPath to the target boolean(s)
      # @return [Array, Object, nil] +1+/+0+ for the new true/false value(s): an Array for a
      #   JSONPath, a single value for a legacy path; nil for a non-boolean match
      def json_toggle(key, path)
        send_command([:"JSON.TOGGLE", key, path])
      end

      # Report the size in bytes of the JSON value(s) at +path+ (the JSON.DEBUG MEMORY
      # subcommand). When +path+ is omitted it defaults to the root.
      #
      # @example
      #   redis.json_debug_memory("doc")
      #     # => 264
      #
      # @param [String] key
      # @param [String] path an optional JSONPath (defaults to the root)
      # @return [Array<Integer>, Integer] the size(s) in bytes: an Array for a JSONPath, a single
      #   integer for a legacy path or when no path is given (0 for a missing key)
      def json_debug_memory(key, path = nil)
        args = [:"JSON.DEBUG", "MEMORY", key]
        args << path if path
        send_command(args)
      end

      private

      # RedisJSON distinguishes JSONPath expressions (which start with "$") from legacy paths.
      # JSONPath queries return an array of matches; legacy paths return a single value.
      def json_path?(path)
        path.to_s.start_with?("$")
      end
    end
  end
end
