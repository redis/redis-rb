# frozen_string_literal: true

class Redis
  module Commands
    module Sets
      # Get the number of members in a set.
      #
      # @param [String] key
      # @return [Integer]
      def scard(key)
        send_command([:scard, key])
      end

      # Add one or more members to a set.
      #
      # @param [String] key
      # @param [String, Array<String>] member one member, or array of members
      # @return [Integer] The number of members that were successfully added
      def sadd(key, *members)
        members.flatten!(1)
        send_command([:sadd, key].concat(members))
      end

      # Add one or more members to a set.
      #
      # @param [String] key
      # @param [String, Array<String>] member one member, or array of members
      # @return [Boolean] Wether at least one member was successfully added.
      def sadd?(key, *members)
        members.flatten!(1)
        send_command([:sadd, key].concat(members), &Boolify)
      end

      # Remove one or more members from a set.
      #
      # @param [String] key
      # @param [String, Array<String>] member one member, or array of members
      # @return [Integer] The number of members that were successfully removed
      def srem(key, *members)
        members.flatten!(1)
        send_command([:srem, key].concat(members))
      end

      # Remove one or more members from a set.
      #
      # @param [String] key
      # @param [String, Array<String>] member one member, or array of members
      # @return [Boolean] Wether at least one member was successfully removed.
      def srem?(key, *members)
        members.flatten!(1)
        send_command([:srem, key].concat(members), &Boolify)
      end

      # Remove and return one or more random member from a set.
      #
      # @param [String] key
      # @return [String]
      # @param [Integer] count
      def spop(key, count = nil)
        if count.nil?
          send_command([:spop, key])
        else
          send_command([:spop, key, Integer(count)])
        end
      end

      # Get one or more random members from a set.
      #
      # @param [String] key
      # @param [Integer] count
      # @return [String]
      def srandmember(key, count = nil)
        if count.nil?
          send_command([:srandmember, key])
        else
          send_command([:srandmember, key, count])
        end
      end

      # Move a member from one set to another.
      #
      # @param [String] source source key
      # @param [String] destination destination key
      # @param [String] member member to move from `source` to `destination`
      # @return [Boolean]
      def smove(source, destination, member)
        send_command([:smove, source, destination, member], &Boolify)
      end

      # Determine if a given value is a member of a set.
      #
      # @param [String] key
      # @param [String] member
      # @return [Boolean]
      def sismember(key, member)
        send_command([:sismember, key, member], &Boolify)
      end

      # Determine if multiple values are members of a set.
      #
      # @param [String] key
      # @param [String, Array<String>] members
      # @return [Array<Boolean>]
      def smismember(key, *members)
        members.flatten!(1)
        send_command([:smismember, key].concat(members)) do |reply|
          reply.map(&Boolify)
        end
      end

      # Get all the members in a set.
      #
      # @param [String] key
      # @return [Array<String>]
      def smembers(key)
        send_command([:smembers, key])
      end

      # Subtract multiple sets.
      #
      # @param [String, Array<String>] keys keys pointing to sets to subtract
      # @return [Array<String>] members in the difference
      def sdiff(*keys)
        keys.flatten!(1)
        send_command([:sdiff].concat(keys))
      end

      # Subtract multiple sets and store the resulting set in a key.
      #
      # @param [String] destination destination key
      # @param [String, Array<String>] keys keys pointing to sets to subtract
      # @return [Integer] number of elements in the resulting set
      def sdiffstore(destination, *keys)
        keys.flatten!(1)
        send_command([:sdiffstore, destination].concat(keys))
      end

      # Get the number of members in the difference between the first set and
      # all successive sets.
      #
      # @example
      #   redis.sadd("foo", ["s1", "s2", "s3"])
      #   redis.sadd("bar", "s3")
      #   redis.sdiffcard("foo", "bar")
      #     # => 2
      #
      # @param [String, Array<String>] keys keys pointing to sets to subtract
      # @param [Integer] limit stop counting once the difference reaches `limit`
      #   members (`0` means unlimited)
      # @return [Integer] number of members in the difference
      def sdiffcard(*keys, limit: nil)
        keys.flatten!(1)
        args = [:sdiffcard, keys.size].concat(keys)
        args << "LIMIT" << Integer(limit) if limit
        send_command(args)
      end

      # Intersect multiple sets.
      #
      # @param [String, Array<String>] keys keys pointing to sets to intersect
      # @return [Array<String>] members in the intersection
      def sinter(*keys)
        keys.flatten!(1)
        send_command([:sinter].concat(keys))
      end

      # Get the number of members in the intersection of multiple sets.
      #
      # @example
      #   redis.sadd("foo", ["s1", "s2", "s3"])
      #   redis.sadd("bar", ["s2", "s3", "s4"])
      #   redis.sintercard("foo", "bar")
      #     # => 2
      # @example Stop counting once the intersection reaches 1 member
      #   redis.sintercard("foo", "bar", limit: 1)
      #     # => 1
      #
      # @param [String, Array<String>] keys keys pointing to sets to intersect
      # @param [Integer] limit stop counting once the intersection reaches `limit`
      #   members (`0` means unlimited)
      # @return [Integer] number of members in the intersection
      def sintercard(*keys, limit: nil)
        keys.flatten!(1)
        args = [:sintercard, keys.size].concat(keys)
        args << "LIMIT" << Integer(limit) if limit
        send_command(args)
      end

      # Intersect multiple sets and store the resulting set in a key.
      #
      # @param [String] destination destination key
      # @param [String, Array<String>] keys keys pointing to sets to intersect
      # @return [Integer] number of elements in the resulting set
      def sinterstore(destination, *keys)
        keys.flatten!(1)
        send_command([:sinterstore, destination].concat(keys))
      end

      # Add multiple sets.
      #
      # @param [String, Array<String>] keys keys pointing to sets to unify
      # @return [Array<String>] members in the union
      def sunion(*keys)
        keys.flatten!(1)
        send_command([:sunion].concat(keys))
      end

      # Add multiple sets and store the resulting set in a key.
      #
      # @param [String] destination destination key
      # @param [String, Array<String>] keys keys pointing to sets to unify
      # @return [Integer] number of elements in the resulting set
      def sunionstore(destination, *keys)
        keys.flatten!(1)
        send_command([:sunionstore, destination].concat(keys))
      end

      # Get the number of distinct members in the union of multiple sets.
      #
      # @example
      #   redis.sadd("foo", ["s1", "s2", "s3"])
      #   redis.sadd("bar", ["s3", "s4"])
      #   redis.sunioncard("foo", "bar")
      #     # => 4
      #
      # @param [String, Array<String>] keys keys pointing to sets to unify
      # @param [Boolean] approx return an approximate cardinality computed with HyperLogLog
      # @param [Integer] limit stop counting once the union reaches `limit`
      #   members (`0` means unlimited)
      # @return [Integer] number of distinct members in the union
      def sunioncard(*keys, approx: false, limit: nil)
        keys.flatten!(1)
        args = [:sunioncard, keys.size].concat(keys)
        args << "APPROX" if approx
        args << "LIMIT" << Integer(limit) if limit
        send_command(args)
      end

      # Scan a set
      #
      # @example Retrieve the first batch of keys in a set
      #   redis.sscan("set", 0)
      #
      # @param [String, Integer] cursor the cursor of the iteration
      # @param [Hash] options
      #   - `:match => String`: only return keys matching the pattern
      #   - `:count => Integer`: return count keys at most per iteration
      #
      # @return [String, Array<String>] the next cursor and all found members
      #
      # See the [Redis Server SSCAN documentation](https://redis.io/docs/latest/commands/sscan/) for further details
      def sscan(key, cursor, **options)
        _scan(:sscan, cursor, [key], **options)
      end

      # Scan a set
      #
      # @example Retrieve all of the keys in a set
      #   redis.sscan_each("set").to_a
      #   # => ["key1", "key2", "key3"]
      #
      # @param [Hash] options
      #   - `:match => String`: only return keys matching the pattern
      #   - `:count => Integer`: return count keys at most per iteration
      #
      # @return [Enumerator] an enumerator for all keys in the set
      #
      # See the [Redis Server SSCAN documentation](https://redis.io/docs/latest/commands/sscan/) for further details
      def sscan_each(key, **options, &block)
        return to_enum(:sscan_each, key, **options) unless block_given?

        cursor = 0
        loop do
          cursor, keys = sscan(key, cursor, **options)
          keys.each(&block)
          break if cursor == "0"
        end
      end

      # Sets the time to live in seconds for one or more set members. An
      # expired member is removed from the set; a TTL of `0` removes it
      # immediately.
      #
      # @example
      #   redis.sadd("set", "m1")
      #   redis.sexpire("set", 10, "m1", "m2") # => [1, -2]
      #   redis.sexpire("set", 10, "m1", "m2", nx: true) # => [0, -2]
      #
      # @param [String] key
      # @param [Integer] ttl
      # @param [Hash] options
      #   - `:nx => true`: Set expiry only when the member has no expiry.
      #   - `:xx => true`: Set expiry only when the member has an existing expiry.
      #   - `:gt => true`: Set expiry only when the new expiry is greater than current one.
      #   - `:lt => true`: Set expiry only when the new expiry is less than current one.
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: `1` set, `0` condition not met,
      #   `2` deleted (TTL `0`), `-2` no such member or key.
      # @raise [ArgumentError] when more than one of `:nx`, `:xx`, `:gt`, `:lt` is given
      def sexpire(key, ttl, *members, nx: nil, xx: nil, gt: nil, lt: nil)
        members.flatten!(1)
        args = [:sexpire, key, Integer(ttl)]
        args.concat(hash_field_expiration_condition(nx, xx, gt, lt))
        args.concat(['MEMBERS', members.length, *members])

        send_command(args)
      end

      # Sets the time to live in milliseconds for one or more set members. An
      # expired member is removed from the set; a TTL of `0` removes it
      # immediately.
      #
      # @example
      #   redis.sadd("set", "m1")
      #   redis.spexpire("set", 500, "m1", "m2") # => [1, -2]
      #   redis.spexpire("set", 500, "m1", "m2", nx: true) # => [0, -2]
      #
      # @param [String] key
      # @param [Integer] ttl
      # @param [Hash] options
      #   - `:nx => true`: Set expiry only when the member has no expiry.
      #   - `:xx => true`: Set expiry only when the member has an existing expiry.
      #   - `:gt => true`: Set expiry only when the new expiry is greater than current one.
      #   - `:lt => true`: Set expiry only when the new expiry is less than current one.
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: `1` set, `0` condition not met,
      #   `2` deleted (TTL `0`), `-2` no such member or key.
      # @raise [ArgumentError] when more than one of `:nx`, `:xx`, `:gt`, `:lt` is given
      def spexpire(key, ttl, *members, nx: nil, xx: nil, gt: nil, lt: nil)
        members.flatten!(1)
        args = [:spexpire, key, Integer(ttl)]
        args.concat(hash_field_expiration_condition(nx, xx, gt, lt))
        args.concat(['MEMBERS', members.length, *members])

        send_command(args)
      end

      # Sets the expiration for one or more set members as an absolute Unix
      # timestamp in seconds. A timestamp in the past removes the member
      # immediately.
      #
      # @example
      #   redis.sadd("set", "m1")
      #   redis.sexpireat("set", Time.now.to_i + 10, "m1", "m2") # => [1, -2]
      #   redis.sexpireat("set", Time.now.to_i - 10, "m1") # => [2]
      #
      # @param [String] key
      # @param [Integer] unix_time_seconds absolute expiration timestamp in seconds since epoch
      # @param [Hash] options
      #   - `:nx => true`: Set expiry only when the member has no expiry.
      #   - `:xx => true`: Set expiry only when the member has an existing expiry.
      #   - `:gt => true`: Set expiry only when the new expiry is greater than current one.
      #   - `:lt => true`: Set expiry only when the new expiry is less than current one.
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: `1` set, `0` condition not met,
      #   `2` deleted (past timestamp), `-2` no such member or key.
      # @raise [ArgumentError] when more than one of `:nx`, `:xx`, `:gt`, `:lt` is given
      def sexpireat(key, unix_time_seconds, *members, nx: nil, xx: nil, gt: nil, lt: nil)
        members.flatten!(1)
        args = [:sexpireat, key, Integer(unix_time_seconds)]
        args.concat(hash_field_expiration_condition(nx, xx, gt, lt))
        args.concat(['MEMBERS', members.length, *members])

        send_command(args)
      end

      # Sets the expiration for one or more set members as an absolute Unix
      # timestamp in milliseconds. A timestamp in the past removes the member
      # immediately.
      #
      # @example
      #   redis.sadd("set", "m1")
      #   redis.spexpireat("set", (Time.now.to_f * 1000).to_i + 500, "m1", "m2") # => [1, -2]
      #   redis.spexpireat("set", (Time.now.to_f * 1000).to_i - 500, "m1") # => [2]
      #
      # @param [String] key
      # @param [Integer] unix_time_milliseconds absolute expiration timestamp in milliseconds since epoch
      # @param [Hash] options
      #   - `:nx => true`: Set expiry only when the member has no expiry.
      #   - `:xx => true`: Set expiry only when the member has an existing expiry.
      #   - `:gt => true`: Set expiry only when the new expiry is greater than current one.
      #   - `:lt => true`: Set expiry only when the new expiry is less than current one.
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: `1` set, `0` condition not met,
      #   `2` deleted (past timestamp), `-2` no such member or key.
      # @raise [ArgumentError] when more than one of `:nx`, `:xx`, `:gt`, `:lt` is given
      def spexpireat(key, unix_time_milliseconds, *members, nx: nil, xx: nil, gt: nil, lt: nil)
        members.flatten!(1)
        args = [:spexpireat, key, Integer(unix_time_milliseconds)]
        args.concat(hash_field_expiration_condition(nx, xx, gt, lt))
        args.concat(['MEMBERS', members.length, *members])

        send_command(args)
      end

      # Returns the time to live in seconds for one or more set members.
      #
      # @example
      #   redis.sadd("set", "m1", "m2")
      #   redis.sexpire("set", 10, "m1") # => [1]
      #   redis.sttl("set", "m1", "m2", "m3") # => [10, -1, -2]
      #
      # @param [String] key
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: the TTL in seconds, `-1` when the
      #   member has no expiry, `-2` when the member or key does not exist.
      def sttl(key, *members)
        members.flatten!(1)
        send_command([:sttl, key, 'MEMBERS', members.length, *members])
      end

      # Returns the time to live in milliseconds for one or more set members.
      #
      # @example
      #   redis.sadd("set", "m1", "m2")
      #   redis.spexpire("set", 500, "m1") # => [1]
      #   redis.spttl("set", "m1", "m2", "m3") # => [500, -1, -2]
      #
      # @param [String] key
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: the TTL in milliseconds, `-1` when
      #   the member has no expiry, `-2` when the member or key does not exist.
      def spttl(key, *members)
        members.flatten!(1)
        send_command([:spttl, key, 'MEMBERS', members.length, *members])
      end

      # Returns the expiration time of one or more set members as an absolute
      # Unix timestamp in seconds.
      #
      # @example
      #   redis.sadd("set", "m1", "m2")
      #   redis.sexpireat("set", Time.now.to_i + 100, "m1")
      #   redis.sexpiretime("set", "m1", "m2", "m3") # => [<unix timestamp in seconds>, -1, -2]
      #
      # @param [String] key
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: the expiration Unix timestamp in
      #   seconds, `-1` when the member has no expiry, `-2` when the member or
      #   key does not exist.
      def sexpiretime(key, *members)
        members.flatten!(1)
        send_command([:sexpiretime, key, 'MEMBERS', members.length, *members])
      end

      # Returns the expiration time of one or more set members as an absolute
      # Unix timestamp in milliseconds.
      #
      # @example
      #   redis.sadd("set", "m1", "m2")
      #   redis.spexpireat("set", (Time.now.to_f * 1000).to_i + 100_000, "m1")
      #   redis.spexpiretime("set", "m1", "m2", "m3") # => [<unix timestamp in milliseconds>, -1, -2]
      #
      # @param [String] key
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: the expiration Unix timestamp in
      #   milliseconds, `-1` when the member has no expiry, `-2` when the member
      #   or key does not exist.
      def spexpiretime(key, *members)
        members.flatten!(1)
        send_command([:spexpiretime, key, 'MEMBERS', members.length, *members])
      end

      # Removes the expiration from one or more set members, making them
      # persistent.
      #
      # @example
      #   redis.sadd("set", "m1", "m2")
      #   redis.sexpire("set", 100, "m1")
      #   redis.spersist("set", "m1", "m2", "m3") # => [1, -1, -2]
      #
      # @param [String] key
      # @param [Array<String>] members
      # @return [Array<Integer>] per member: `1` when the expiration was
      #   removed, `-1` when the member has no expiry, `-2` when the member or
      #   key does not exist.
      def spersist(key, *members)
        members.flatten!(1)
        send_command([:spersist, key, 'MEMBERS', members.length, *members])
      end
    end
  end
end
