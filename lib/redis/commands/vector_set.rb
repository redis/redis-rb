# frozen_string_literal: true

require "json"

class Redis
  module Commands
    module VectorSet
      # Add vector for element to a vector set
      #
      # @param [String] key the vector set key
      # @param [Array<Float>, String] vector the vector as array of floats or FP32 blob
      # @param [String] element the element name
      # @param [Hash] options optional parameters
      # @option options [Integer] :reduce_dim dimensions to reduce the vector to
      # @option options [Boolean] :cas use CAS (check-and-set) when adding
      # @option options [String] :quantization quantization type (NOQUANT, BIN, Q8)
      # @option options [Integer, Float] :ef exploration factor
      # @option options [Hash, String] :attributes JSON attributes for the element
      # @option options [Integer] :numlinks number of links (M parameter)
      #
      # @return [Integer] 1 if element was added, 0 if updated
      #
      # @see https://redis.io/commands/vadd
      def vadd(key, vector, element, **options)
        args = [:vadd, key]

        # Add REDUCE option if specified
        if options[:reduce_dim]
          args << "REDUCE" << options[:reduce_dim]
        end

        # Add vector in FP32 or VALUES format
        if vector.is_a?(String) && vector.encoding == Encoding::BINARY
          # Binary FP32 blob
          args << "FP32" << vector
        elsif vector.is_a?(Array)
          # VALUES format
          args << "VALUES" << vector.length
          args.concat(vector)
        else
          raise ArgumentError, "Vector must be a binary String or an Array"
        end

        # Add element name
        args << element

        # Add CAS option if specified
        args << "CAS" if options[:cas]

        # Add quantization option if specified
        if options[:quantization]
          args << options[:quantization].to_s.upcase
        end

        # Add EF option if specified
        if options[:ef]
          args << "EF" << options[:ef]
        end

        # Add attributes if specified
        if options[:attributes]
          attrs_json = if options[:attributes].is_a?(Hash)
            ::JSON.generate(options[:attributes])
          else
            options[:attributes]
          end
          args << "SETATTR" << attrs_json
        end

        # Add numlinks (M parameter) if specified
        if options[:numlinks]
          args << "M" << options[:numlinks]
        end

        send_command(args)
      end

      # Compare a vector or element with other vectors in a vector set
      #
      # @param [String] key the vector set key
      # @param [Array<Float>, String] input vector, FP32 blob, or element name
      # @param [Hash] options search parameters
      # @option options [Boolean] :with_scores return similarity scores
      # @option options [Boolean] :with_attribs return attributes
      # @option options [Integer] :count number of results to return
      # @option options [Integer, Float] :ef exploration factor
      # @option options [String] :filter filter expression
      # @option options [String] :filter_ef max filtering effort
      # @option options [Boolean] :truth force linear scan
      # @option options [Boolean] :no_thread execute in main thread
      # @option options [Float] :epsilon distance threshold (0-1)
      #
      # @return [Array, Hash] list of elements or hash with scores/attributes
      #
      # @see https://redis.io/commands/vsim
      def vsim(key, input, **options)
        args = [:vsim, key]

        # Add input in FP32, VALUES, or ELE format
        if input.is_a?(String) && input.encoding == Encoding::BINARY
          # Binary FP32 blob
          args << "FP32" << input
        elsif input.is_a?(Array)
          # VALUES format
          args << "VALUES" << input.length
          args.concat(input)
        elsif input.is_a?(String)
          # Element name
          args << "ELE" << input
        end

        # Add WITHSCORES option
        args << "WITHSCORES" if options[:with_scores]

        # Add WITHATTRIBS option
        args << "WITHATTRIBS" if options[:with_attribs]

        # Add COUNT option
        if options[:count]
          args << "COUNT" << options[:count]
        end

        # Add EPSILON option
        if options[:epsilon]
          args << "EPSILON" << options[:epsilon]
        end

        # Add EF option
        if options[:ef]
          args << "EF" << options[:ef]
        end

        # Add FILTER option
        if options[:filter]
          args << "FILTER" << options[:filter]
        end

        # Add FILTER-EF option
        if options[:filter_ef]
          args << "FILTER-EF" << options[:filter_ef]
        end

        # Add TRUTH option
        args << "TRUTH" if options[:truth]

        # Add NOTHREAD option
        args << "NOTHREAD" if options[:no_thread]

        send_command(args) do |reply|
          # Parse response based on options
          if options[:with_scores] && options[:with_attribs]
            # Return hash with structure: {element => {score: ..., attributes: ...}}
            parse_vsim_with_scores_and_attribs(reply)
          elsif options[:with_scores]
            # Return hash with scores: {element => score}
            Floatify.call(reply)
          elsif options[:with_attribs]
            # Return hash with attributes: {element => attributes}
            parse_vsim_with_attribs(reply)
          else
            # Return array of elements
            reply
          end
        end
      end

      # Get the dimension of a vector set
      #
      # @param [String] key the vector set key
      # @return [Integer] the dimension
      #
      # @see https://redis.io/commands/vdim
      def vdim(key)
        send_command([:vdim, key])
      end

      # Get the cardinality (number of elements) of a vector set
      #
      # @param [String] key the vector set key
      # @return [Integer] the cardinality
      #
      # @see https://redis.io/commands/vcard
      def vcard(key)
        send_command([:vcard, key])
      end

      # Remove an element from a vector set
      #
      # @param [String] key the vector set key
      # @param [String] element the element name
      # @return [Integer] 1 if removed, 0 if not found
      #
      # @see https://redis.io/commands/vrem
      def vrem(key, element)
        send_command([:vrem, key, element])
      end

      # Get the approximated vector of an element
      #
      # @param [String] key the vector set key
      # @param [String] element the element name
      # @param [Hash] options optional parameters
      # @option options [Boolean] :raw return internal representation
      #
      # @return [Array<Float>, Hash, nil] the vector or nil if not found
      #
      # @see https://redis.io/commands/vemb
      def vemb(key, element, **options)
        args = [:vemb, key, element]
        args << "RAW" if options[:raw]

        send_command(args) do |reply|
          if options[:raw] && reply
            # Parse RAW response as hash
            parse_vemb_raw(reply)
          elsif reply.is_a?(Array)
            # Convert string array to float array
            reply.map(&:to_f)
          else
            reply
          end
        end
      end

      # Get the neighbors for each level an element exists in
      #
      # @param [String] key the vector set key
      # @param [String] element the element name
      # @param [Hash] options optional parameters
      # @option options [Boolean] :with_scores return scores
      #
      # @return [Array<Array>, Array<Hash>, nil] neighbors per level or nil if not found
      #
      # @see https://redis.io/commands/vlinks
      def vlinks(key, element, **options)
        args = [:vlinks, key, element]
        args << "WITHSCORES" if options[:with_scores]

        send_command(args) do |reply|
          if reply && options[:with_scores]
            # Convert each level's response to hash
            reply.map { |level| Floatify.call(level) }
          else
            reply
          end
        end
      end

      # Get information about a vector set
      #
      # @param [String] key the vector set key
      # @return [Hash] information about the vector set
      #
      # @see https://redis.io/commands/vinfo
      def vinfo(key)
        send_command([:vinfo, key], &Hashify)
      end

      # Associate or remove JSON attributes of an element
      #
      # @param [String] key the vector set key
      # @param [String] element the element name
      # @param [Hash, String] attributes JSON attributes or empty hash to remove
      #
      # @return [Integer] 1 on success
      #
      # @see https://redis.io/commands/vsetattr
      def vsetattr(key, element, attributes)
        attrs_json = if attributes.is_a?(Hash)
          attributes.empty? ? "{}" : ::JSON.generate(attributes)
        else
          attributes
        end

        send_command([:vsetattr, key, element, attrs_json])
      end

      # Retrieve the JSON attributes of an element
      #
      # @param [String] key the vector set key
      # @param [String] element the element name
      #
      # @return [Hash, nil] the attributes or nil if not found/empty
      #
      # @see https://redis.io/commands/vgetattr
      def vgetattr(key, element)
        send_command([:vgetattr, key, element]) do |reply|
          if reply
            attrs = ::JSON.parse(reply)
            # Return nil for empty hash (no attributes set)
            attrs.empty? ? nil : attrs
          end
        rescue ::JSON::ParserError
          nil
        end
      end

      # Get random elements from a vector set
      #
      # @param [String] key the vector set key
      # @param [Integer, nil] count number of elements to return
      #
      # @return [String, Array<String>, nil] random element(s) or nil if set doesn't exist
      #
      # @see https://redis.io/commands/vrandmember
      def vrandmember(key, count = nil)
        args = [:vrandmember, key]
        args << count if count

        send_command(args)
      end

      private

      # Parse VSIM response with both scores and attributes
      def parse_vsim_with_scores_and_attribs(reply)
        return {} unless reply

        result = {}
        reply.each_slice(3) do |element, score, attribs|
          parsed_attribs = if attribs
            attrs = ::JSON.parse(attribs)
            attrs.empty? ? nil : attrs
          end
          result[element] = {
            "score" => score.to_f,
            "attributes" => parsed_attribs
          }
        end
        result
      rescue ::JSON::ParserError
        {}
      end

      # Parse VSIM response with only attributes
      def parse_vsim_with_attribs(reply)
        return {} unless reply

        result = {}
        reply.each_slice(2) do |element, attribs|
          if attribs
            parsed = ::JSON.parse(attribs)
            result[element] = parsed.empty? ? nil : parsed
          else
            result[element] = nil
          end
        end
        result
      rescue ::JSON::ParserError
        {}
      end

      # Parse VEMB RAW response
      def parse_vemb_raw(reply)
        return nil unless reply.is_a?(Array) && reply.length >= 3

        result = {
          "quantization" => reply[0],
          "raw" => reply[1],
          "l2" => reply[2].to_f
        }

        # Add range if present (for quantized vectors)
        result["range"] = reply[3].to_f if reply.length > 3

        result
      end
    end
  end
end
