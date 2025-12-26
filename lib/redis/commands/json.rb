# frozen_string_literal: true

require 'json'

class Redis
  module Commands
    module JSON
      # Set JSON value at path in key
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @param [Object] value the value to set (will be JSON-encoded)
      # @param [Boolean] nx only set if key doesn't exist
      # @param [Boolean] xx only set if key exists
      # @return [String] 'OK' on success, nil if NX/XX conditions not met
      #
      # @example Set a JSON document
      #   redis.json_set('user:1', '$', {name: 'John', age: 30})
      #
      # @example Set only if key doesn't exist
      #   redis.json_set('user:1', '$', {name: 'John'}, nx: true)
      def json_set(key, path, value, nx: false, xx: false)
        args = ['JSON.SET', key, path, value.to_json]
        args << 'NX' if nx
        args << 'XX' if xx
        send_command(args)
      end

      # Get JSON value(s) at path(s) from a key
      #
      # @param [String] key the Redis key
      # @param [Array<String>] paths one or more JSON paths (defaults to root '$')
      # @return [Hash, Array, String, Numeric, Boolean, nil] the JSON value(s)
      #
      # @example Get entire JSON document
      #   redis.json_get('user:1')
      #
      # @example Get specific paths
      #   redis.json_get('user:1', '$.name', '$.email')
      def json_get(key, *paths)
        args = ['JSON.GET', key]
        args.concat(paths) unless paths.empty?
        parse_json(send_command(args))
      end

      # Get JSON values at path from multiple keys
      #
      # @param [Array<String>] keys the Redis keys
      # @param [String] path the JSON path
      # @return [Array] array of JSON values, one per key
      #
      # @example Get name from multiple user keys
      #   redis.json_mget(['user:1', 'user:2'], '$.name')
      def json_mget(keys, path)
        args = ['JSON.MGET'].concat(keys) << path
        send_command(args).map { |item| parse_json(item) }
      end

      # Delete JSON value(s) at path in key
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Integer] number of paths deleted
      #
      # @example Delete a specific field
      #   redis.json_del('user:1', '$.email')
      def json_del(key, path = '$')
        send_command(['JSON.DEL', key, path])
      end

      # Alias for json_del (Redis command alias)
      alias json_forget json_del

      # Get the type of JSON value at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [String, Array<String>] type(s) of value ('object', 'array', 'string', 'number', 'boolean', 'null')
      def json_type(key, path = '$')
        send_command(['JSON.TYPE', key, path])
      end

      # Increment numeric value(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Numeric] number the number to add
      # @return [String, Array] the new value(s) as JSON string
      def json_numincrby(key, path, number)
        parse_json(send_command(['JSON.NUMINCRBY', key, path, number.to_s]))
      end

      # Multiply numeric value(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Numeric] number the number to multiply by
      # @return [String, Array] the new value(s) as JSON string
      def json_nummultby(key, path, number)
        parse_json(send_command(['JSON.NUMMULTBY', key, path, number.to_s]))
      end

      # Append string value(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [String] value the string to append
      # @return [Integer, Array<Integer>] new length(s) of string(s)
      def json_strappend(key, path, value)
        send_command(['JSON.STRAPPEND', key, path, value.to_json])
      end

      # Get length of string(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Integer, Array<Integer>, nil] length(s) of string(s)
      def json_strlen(key, path = '$')
        send_command(['JSON.STRLEN', key, path])
      end

      # Append value(s) to array(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Array<Object>] values one or more values to append
      # @return [Integer, Array<Integer>] new length(s) of array(s)
      def json_arrappend(key, path, *values)
        send_command(['JSON.ARRAPPEND', key, path].concat(values.map(&:to_json)))
      end

      # Find index of value in array(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Object] value the value to search for
      # @param [Integer] start start index (defaults to 0)
      # @param [Integer] stop stop index (defaults to 0, meaning end of array)
      # @return [Integer, Array<Integer>] index(es) of value, -1 if not found
      def json_arrindex(key, path, value, start = 0, stop = 0)
        send_command(['JSON.ARRINDEX', key, path, value.to_json, start.to_s, stop.to_s])
      end

      # Insert value(s) into array(s) at path before index
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Integer] index the array index
      # @param [Array<Object>] values one or more values to insert
      # @return [Integer, Array<Integer>] new length(s) of array(s)
      def json_arrinsert(key, path, index, *values)
        send_command(['JSON.ARRINSERT', key, path, index.to_s].concat(values.map(&:to_json)))
      end

      # Get length of array(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Integer, Array<Integer>, nil] length(s) of array(s)
      def json_arrlen(key, path = '$')
        send_command(['JSON.ARRLEN', key, path])
      end

      # Remove and return element from array at index
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @param [Integer] index the array index (defaults to -1, last element)
      # @return [Object, Array] the popped value(s)
      def json_arrpop(key, path = '$', index = -1)
        parse_json(send_command(['JSON.ARRPOP', key, path, Integer(index).to_s]))
      end

      # Trim array(s) at path to specified range
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Integer] start start index (inclusive)
      # @param [Integer] stop stop index (inclusive)
      # @return [Integer, Array<Integer>] new length(s) of array(s)
      def json_arrtrim(key, path, start, stop)
        send_command(['JSON.ARRTRIM', key, path, start.to_s, stop.to_s])
      end

      # Get keys of object(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Array<String>, Array<Array<String>>] key(s) of object(s)
      def json_objkeys(key, path = '$')
        send_command(['JSON.OBJKEYS', key, path])
      end

      # Get number of keys in object(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Integer, Array<Integer>, nil] number of keys in object(s)
      def json_objlen(key, path = '$')
        send_command(['JSON.OBJLEN', key, path])
      end

      # Set multiple JSON values atomically
      #
      # @param [Array<Array>] triplets array of [key, path, value] triplets
      # @return [String] 'OK'
      #
      # @example
      #   redis.json_mset([
      #     ['user:1', '$', {name: 'John'}],
      #     ['user:2', '$', {name: 'Jane'}]
      #   ])
      def json_mset(triplets)
        pieces = []
        triplets.each do |key, path, value|
          pieces.concat([key, path.to_s, value.to_json])
        end
        send_command(["JSON.MSET", *pieces])
      end

      # Merge JSON value at path with provided value
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @param [Object] value the value to merge
      # @return [String] 'OK'
      def json_merge(key, path, value)
        send_command(["JSON.MERGE", key, path, value.to_json])
      end

      # Toggle boolean value(s) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path
      # @return [Integer, Array<Integer>] new value(s) (0 or 1)
      def json_toggle(key, path)
        send_command(['JSON.TOGGLE', key, path])
      end

      # Clear container values (arrays/objects) at path
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Integer] number of values cleared
      def json_clear(key, path = '$')
        send_command(['JSON.CLEAR', key, path])
      end

      # Get JSON value(s) in RESP format
      #
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Array] RESP representation of value(s)
      def json_resp(key, path = '$')
        send_command(['JSON.RESP', key, path])
      end

      # Run JSON debug command
      #
      # @param [String] subcommand debug subcommand ('MEMORY', 'HELP')
      # @param [String] key the Redis key
      # @param [String] path the JSON path (defaults to root '$')
      # @return [Integer, Array] depends on subcommand
      def json_debug(subcommand, key, path = '$')
        send_command(['JSON.DEBUG', subcommand, key, path])
      end

      private

      def parse_json(value)
        case value
        when String
          ::JSON.parse(value, symbolize_names: true)
        when Array
          value.map { |v| parse_json(v) }
        else
          value
        end
      rescue ::JSON::ParserError => e
        raise Redis::JSONParseError, "Failed to parse JSON: #{e.message}"
      end
    end
  end
end
