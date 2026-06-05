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
    end
  end
end
