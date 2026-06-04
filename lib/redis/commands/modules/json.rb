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
      #     # => true
      #
      # @example pre-encoded JSON
      #   redis.json_set("doc", "$", '{"a":1}', raw: true)
      #     # => true
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
      def json_set(key, path, value, nx: false, xx: false, raw: false)
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
    end
  end
end
