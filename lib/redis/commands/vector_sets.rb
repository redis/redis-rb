# frozen_string_literal: true

require "json"

class Redis
  module Commands
    module VectorSets
      # Add a new element into a vector set, or update its vector if it
      # already exists.
      #
      # The vector can be given as an Array of numbers (sent as `VALUES`), or
      # as a String holding a little-endian FP32 blob (sent as `FP32`), e.g.
      # `values.pack("e*")`.
      #
      # @example Add an element with an array of values
      #   redis.vadd("mykey", [0.1, 1.2, 0.5], "my-element")
      #     # => true
      # @example Add an element with an FP32 blob
      #   redis.vadd("mykey", [0.1, 1.2, 0.5].pack("e*"), "my-element")
      #     # => true
      # @example Reduce dimensionality and attach attributes
      #   redis.vadd("mykey", [0.1, 1.2, 0.5], "my-element", reduce: 2, attributes: { size: "large" })
      #     # => true
      #
      # @param [String] key
      # @param [Array<Numeric>, String] vector the vector as an array of
      #   numbers, or a little-endian FP32 blob
      # @param [String] element name of the element being added
      # @param [Hash] options
      # @option options [Integer] :reduce project the vector down to this
      #   number of dimensions
      # @option options [Boolean] :cas collect neighbor candidates in a
      #   background thread, check-and-set style
      # @option options [Symbol, String] :quantization one of `:noquant`,
      #   `:q8` (the default) or `:bin`
      # @option options [Integer] :ef build-time exploration factor (default 200)
      # @option options [Hash, String] :attributes attributes associated with
      #   the element, as an object serialized to JSON or a pre-encoded JSON string
      # @option options [Integer] :m maximum number of connections per graph
      #   node (default 16)
      # @return [Boolean] whether the element was added
      def vadd(key, vector, element, reduce: nil, cas: nil, quantization: nil, ef: nil, attributes: nil, m: nil)
        args = [:vadd, key]
        args << "REDUCE" << Integer(reduce) if reduce

        if vector.is_a?(String)
          args << "FP32" << vector
        else
          args << "VALUES" << vector.size
          args.concat(vector.map { |value| Float(value) })
        end

        args << element
        args << "CAS" if cas

        if quantization
          case quantization.to_s.downcase
          when "noquant" then args << "NOQUANT"
          when "q8" then args << "Q8"
          when "bin" then args << "BIN"
          else raise ArgumentError, "unknown quantization: #{quantization.inspect}"
          end
        end

        args << "EF" << Integer(ef) if ef

        if attributes
          args << "SETATTR" << (attributes.is_a?(String) ? attributes : ::JSON.generate(attributes))
        end

        args << "M" << Integer(m) if m

        send_command(args, &BoolifyBoolean)
      end

      # Return the number of elements in a vector set.
      #
      # @example
      #   redis.vcard("mykey")
      #     # => 2
      #
      # @param [String] key
      # @return [Integer] the number of elements in the vector set, or 0 if
      #   the key does not exist
      def vcard(key)
        send_command([:vcard, key])
      end

      # Return the number of dimensions of the vectors in a vector set.
      #
      # For a vector set created with the `REDUCE` option this reports the
      # reduced dimension, although full-size vectors must still be used when
      # querying with VSIM.
      #
      # @example
      #   redis.vdim("mykey")
      #     # => 3
      #
      # @param [String] key
      # @return [Integer] the dimension of the vectors in the set
      # @raise [Redis::CommandError] if the key does not exist
      def vdim(key)
        send_command([:vdim, key])
      end

      # Return the approximate vector associated with an element in a vector
      # set. The round trip is approximate because vectors are normalized and
      # (by default) quantized on insertion.
      #
      # @example
      #   redis.vemb("mykey", "my-element")
      #     # => [0.1004752591252327, 1.2000000476837158, 0.5023762512207031]
      # @example Raw internal representation
      #   redis.vemb("mykey", "my-element", raw: true)
      #     # => { "quantization" => "q8", "raw" => "\x0b\x7f5", "l2" => 1.3038404, "range" => 0.009448819 }
      #
      # @param [String] key
      # @param [String] element name of the element whose vector to retrieve
      # @param [Boolean] raw return the raw internal representation instead
      # @return [Array<Float>, Hash, nil] the vector as an array of Floats; with
      #   `raw: true` a Hash with `"quantization"`, `"raw"` (blob), `"l2"` and,
      #   for q8 sets, `"range"` keys; nil if the key or element does not exist
      def vemb(key, element, raw: nil)
        if raw
          send_command([:vemb, key, element, "RAW"], &HashifyVectorEmbeddingRaw)
        else
          send_command([:vemb, key, element], &FloatifyArray)
        end
      end

      # Return the neighbors of an element in a vector set, one entry per
      # layer of the HNSW graph.
      #
      # @example
      #   redis.vlinks("mykey", "elem-1")
      #     # => [["elem-2"]]
      # @example With similarity scores
      #   redis.vlinks("mykey", "elem-1", with_scores: true)
      #     # => [{ "elem-2" => 0.9989262223243713 }]
      #
      # @param [String] key
      # @param [String] element name of the element whose neighbors to inspect
      # @param [Boolean] with_scores include similarity scores for each neighbor
      # @return [Array<Array<String>>, Array<Hash>, nil] one array of neighbor
      #   names per layer; with scores, one `{ name => Float }` Hash per layer;
      #   nil if the key or element does not exist
      def vlinks(key, element, withscores: false, with_scores: withscores)
        if with_scores
          send_command([:vlinks, key, element, "WITHSCORES"], &HashifyVectorLinksWithScores)
        else
          send_command([:vlinks, key, element])
        end
      end

      # Return elements similar to a given vector or element, by approximate
      # (HNSW) or exact (`truth: true`) similarity search.
      #
      # The query is either a vector — an Array of numbers (sent as `VALUES`)
      # or a little-endian FP32 String blob (sent as `FP32`) — or the name of
      # an existing element (sent as `ELE`). Exactly one of `vector:` and
      # `element:` must be given.
      #
      # @example Query by element
      #   redis.vsim("mykey", element: "apple", count: 3)
      #     # => ["apple", "apples", "pear"]
      # @example Query by vector, with similarity scores
      #   redis.vsim("mykey", vector: [0.1, 1.2, 0.5], with_scores: true)
      #     # => { "apple" => 0.9998867657923256, ... }
      # @example With scores and attributes
      #   redis.vsim("mykey", element: "apple", with_scores: true, with_attribs: true)
      #     # => { "apple" => [0.9998867657923256, "{\"len\": 5}"], ... }
      #
      # @param [String] key
      # @param [Hash] options
      # @option options [Array<Numeric>, String] :vector the query vector
      # @option options [String] :element name of an existing element to use
      #   as the similarity reference
      # @option options [Boolean] :with_scores include the similarity score
      #   (1 identical … 0 opposite) for each result
      # @option options [Boolean] :with_attribs include the JSON attributes
      #   (unparsed, nil when absent) for each result
      # @option options [Integer] :count limit the number of results
      # @option options [Float] :epsilon only return elements with a distance
      #   no further than this delta (similarity better than 1 - delta)
      # @option options [Integer] :ef search exploration factor; higher values
      #   improve recall at the cost of speed
      # @option options [String] :filter filter expression over element attributes
      # @option options [Integer] :filter_ef cap on filtering attempts
      # @option options [Boolean] :truth exact linear scan instead of HNSW (O(N))
      # @option options [Boolean] :nothread run in the main thread
      # @return [Array<String>, Hash] element names; with `with_scores:` a
      #   `{ name => Float }` Hash; with `with_scores:` and `with_attribs:` a
      #   `{ name => [Float, String] }` Hash; with `with_attribs:` alone a
      #   `{ name => String }` Hash. Empty when the key does not exist.
      # @raise [Redis::CommandError] if an `element:` reference does not exist
      def vsim(key, vector: nil, element: nil, withscores: false, with_scores: withscores,
               withattribs: false, with_attribs: withattribs, count: nil, epsilon: nil,
               ef: nil, filter: nil, filter_ef: nil, truth: nil, nothread: nil)
        unless vector.nil? ^ element.nil?
          raise ArgumentError, "must provide exactly one of vector or element"
        end

        args = [:vsim, key]
        if element
          args << "ELE" << element
        elsif vector.is_a?(String)
          args << "FP32" << vector
        else
          args << "VALUES" << vector.size
          args.concat(vector.map { |value| Float(value) })
        end
        args << "WITHSCORES" if with_scores
        args << "WITHATTRIBS" if with_attribs
        args << "COUNT" << Integer(count) if count
        args << "EPSILON" << Float(epsilon) if epsilon
        args << "EF" << Integer(ef) if ef
        args << "FILTER" << filter if filter
        args << "FILTER-EF" << Integer(filter_ef) if filter_ef
        args << "TRUTH" if truth
        args << "NOTHREAD" if nothread

        if with_scores && with_attribs
          send_command(args, &HashifyVectorScoresWithAttribs)
        elsif with_scores
          send_command(args, &HashifyVectorScores)
        elsif with_attribs
          send_command(args, &Hashify)
        else
          send_command(args)
        end
      end

      # Remove an element from a vector set. Memory is reclaimed immediately.
      #
      # @example
      #   redis.vrem("mykey", "my-element")
      #     # => true
      #
      # @param [String] key
      # @param [String] element name of the element to remove
      # @return [Boolean] whether the element was removed; false if the key or
      #   element does not exist
      def vrem(key, element)
        send_command([:vrem, key, element], &BoolifyBoolean)
      end

      # Check if an element exists in a vector set.
      #
      # @example
      #   redis.vismember("mykey", "my-element")
      #     # => true
      #
      # @param [String] key
      # @param [String] element name of the element to check for membership
      # @return [Boolean] whether the element exists in the vector set; false
      #   if the key does not exist
      def vismember(key, element)
        send_command([:vismember, key, element], &BoolifyBoolean)
      end

      # Return one or more random elements from a vector set.
      #
      # Behaves like SRANDMEMBER: a positive count returns up to that many
      # distinct elements, a negative count returns exactly that many elements
      # possibly with duplicates, and a count exceeding the set size returns
      # the whole set.
      #
      # @example
      #   redis.vrandmember("mykey")
      #     # => "elem-2"
      # @example With a count
      #   redis.vrandmember("mykey", 2)
      #     # => ["elem-1", "elem-3"]
      #
      # @param [String] key
      # @param [Integer] count number of elements to return; positive for
      #   distinct elements, negative to allow duplicates
      # @return [String, Array<String>, nil] a single element (or nil for a
      #   missing key) without count; an array of elements (empty for a
      #   missing key) with count
      def vrandmember(key, count = nil)
        if count.nil?
          send_command([:vrandmember, key])
        else
          send_command([:vrandmember, key, Integer(count)])
        end
      end

      # Return the elements of a vector set within a lexicographical range,
      # in lexicographical (byte-by-byte) order.
      #
      # Boundaries follow the ZRANGEBYLEX syntax: `"[elem"` inclusive,
      # `"(elem"` exclusive, `"-"` minimum, `"+"` maximum. A negative count
      # returns all elements in the range. VRANGE is a stateless iterator: to
      # paginate, pass the last returned element as an exclusive start on the
      # next call.
      #
      # @example All elements
      #   redis.vrange("mykey", "-", "+")
      #     # => ["elem-1", "elem-2", "elem-3"]
      # @example Paginate, two at a time
      #   redis.vrange("mykey", "-", "+", 2)
      #     # => ["elem-1", "elem-2"]
      #   redis.vrange("mykey", "(elem-2", "+", 2)
      #     # => ["elem-3"]
      #
      # @param [String] key
      # @param [String] start range start: `"[elem"`, `"(elem"` or `"-"`
      # @param [String] stop range end: `"[elem"`, `"(elem"` or `"+"`
      # @param [Integer] count maximum number of elements to return; negative
      #   returns the whole range
      # @return [Array<String>] the elements in the range, empty if the key
      #   does not exist
      def vrange(key, start, stop, count = nil)
        args = [:vrange, key, start, stop]
        args << Integer(count) if count
        send_command(args)
      end

      # Return metadata and internal details about a vector set, including
      # size, dimensions, quantization type, and graph structure.
      #
      # @example
      #   redis.vinfo("mykey")
      #     # => { "quant-type" => "int8", "vector-dim" => 3, "size" => 1, ... }
      #
      # @param [String] key
      # @return [Hash, nil] the vector set metadata, or nil if the key does
      #   not exist
      def vinfo(key)
        send_command([:vinfo, key], &Hashify)
      end

      # Associate JSON attributes with an element in a vector set, update
      # them, or delete them. Attributes can be used in filtered similarity
      # searches with VSIM.
      #
      # @example Set attributes from a Hash
      #   redis.vsetattr("mykey", "my-element", { type: "fruit", color: "red" })
      #     # => true
      # @example Delete the attributes
      #   redis.vsetattr("mykey", "my-element", nil)
      #     # => true
      #
      # @param [String] key
      # @param [String] element name of the element whose attributes to set
      # @param [Hash, String, nil] attributes attributes as an object
      #   serialized to JSON or a pre-encoded JSON string; nil or an empty
      #   string deletes the attributes
      # @return [Boolean] whether the attributes were set; false if the key or
      #   element does not exist
      def vsetattr(key, element, attributes)
        json = case attributes
        when nil then ""
        when String then attributes
        else ::JSON.generate(attributes)
        end
        send_command([:vsetattr, key, element, json], &BoolifyBoolean)
      end

      # Return the JSON attributes associated with an element in a vector set.
      #
      # By default the reply is parsed with JSON.parse; pass +raw: true+ to get
      # the JSON string as stored.
      #
      # @example
      #   redis.vgetattr("mykey", "my-element")
      #     # => { "size" => "large" }
      # @example Raw JSON string
      #   redis.vgetattr("mykey", "my-element", raw: true)
      #     # => "{\"size\": \"large\"}"
      #
      # @param [String] key
      # @param [String] element name of the element whose attributes to retrieve
      # @param [Boolean] raw return the JSON string without parsing it
      # @return [Object, String, nil] the parsed attributes (or the JSON string
      #   with +raw: true+); nil if the key or element does not exist or has no
      #   attributes
      def vgetattr(key, element, raw: false)
        send_command([:vgetattr, key, element]) do |reply|
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
