# frozen_string_literal: true

require "json"

class Redis
  module Commands
    module Search
      # A single document returned by FT.SEARCH.
      #
      # Behaves like a read-only hash over the document's returned fields, while also
      # exposing the document +id+ and, when requested, its +score+ and +payload+.
      class Document
        # @return [String] the document key/id
        # @return [Float, Array, nil] the relevance score (present when WITHSCORES was set),
        #   normalized to a Float across RESP2/RESP3; with EXPLAINSCORE it is +[Float, explanation]+
        # @return [String, nil] the document payload (present when WITHPAYLOADS was set)
        # @return [Hash{String => Object}] the returned fields keyed by field name
        attr_reader :id, :score, :payload, :attributes

        # @param id [String] the document key/id
        # @param attributes [Hash{String => Object}] the returned fields keyed by field name
        # @param score [Float, Array, nil] the relevance score (Float; +[Float, explanation]+ with EXPLAINSCORE)
        # @param payload [String, nil] the document payload
        def initialize(id, attributes: {}, score: nil, payload: nil)
          @id = id
          @attributes = attributes
          @score = score
          @payload = payload
        end

        # Look up a returned field by name.
        #
        # @param key [String, Symbol] the field name
        # @return [Object, nil] the field value, or nil when the field is absent
        def [](key)
          @attributes[key.to_s]
        end

        # @param key [String, Symbol] the field name
        # @return [Boolean] whether the document has the given field
        def key?(key)
          @attributes.key?(key.to_s)
        end

        # The document id plus its returned fields, as a flat hash.
        #
        # @return [Hash{String => Object}] the attributes merged with +"id"+
        def to_h
          @attributes.merge("id" => @id)
        end

        # @param other [Object] the object to compare against
        # @return [Boolean] whether +other+ is a Document with equal id, attributes, score and payload
        def ==(other)
          other.is_a?(Document) &&
            id == other.id &&
            attributes == other.attributes &&
            score == other.score &&
            payload == other.payload
        end
        alias eql? ==

        # @return [Integer] a hash derived from id, attributes, score and payload
        def hash
          [id, attributes, score, payload].hash
        end
      end

      # Result of FT.SEARCH: the total number of matching documents (which may exceed the
      # number returned because of paging) plus the documents on this page.
      class SearchResult
        include Enumerable

        # @return [Integer] the total number of matching documents (may exceed +documents.size+
        #   because of paging)
        # @return [Array<Document>] the documents on this page
        attr_reader :total, :documents

        # @param total [Integer] the total number of matching documents
        # @param documents [Array<Document>] the documents on this page
        def initialize(total, documents)
          @total = total
          @documents = documents
        end

        # Iterate over the documents on this page.
        #
        # @yieldparam document [Document]
        # @return [Enumerator, Array<Document>]
        def each(&block)
          @documents.each(&block)
        end

        # @param index [Integer] the position within this page
        # @return [Document, nil] the document at +index+, or nil when out of range
        def [](index)
          @documents[index]
        end

        # @return [Integer] the number of documents on this page
        def size
          @documents.size
        end
        alias length size

        # @return [Boolean] whether this page has no documents
        def empty?
          @documents.empty?
        end
      end

      # Result of FT.AGGREGATE (and FT.CURSOR READ): the rows produced by the pipeline plus,
      # when WITHCURSOR was requested, the cursor id to read the next batch with (0 when
      # the cursor is exhausted).
      class AggregateResult
        include Enumerable

        # @return [Array<Hash{String => Object}>] the rows produced by the pipeline, each a
        #   field => value hash
        # @return [Integer, nil] the next cursor id (0 when exhausted), or nil when no cursor
        attr_reader :rows, :cursor

        # @param rows [Array<Hash{String => Object}>] the pipeline rows
        # @param cursor [Integer, nil] the next cursor id, or nil when no cursor was requested
        def initialize(rows, cursor: nil)
          @rows = rows
          @cursor = cursor
        end

        # Iterate over the rows.
        #
        # @yieldparam row [Hash{String => Object}]
        # @return [Enumerator, Array<Hash>]
        def each(&block)
          @rows.each(&block)
        end

        # @param index [Integer] the row position
        # @return [Hash, nil] the row at +index+, or nil when out of range
        def [](index)
          @rows[index]
        end

        # @return [Integer] the number of rows
        def size
          @rows.size
        end
        alias length size

        # @return [Boolean] whether there are no rows
        def empty?
          @rows.empty?
        end
      end

      # Result of FT.HYBRID: the fused result rows (each a field => value hash, including the
      # synthetic +"__key"+ and +"__score"+) plus the total, any warnings and the execution time.
      #
      # When the query used WITHCURSOR the server returns per-leg cursor ids instead of an inline
      # page; those are exposed via {#search_cursor} / {#vsim_cursor} and {#cursor?} is true.
      class HybridResult
        include Enumerable

        # @return [Array<Hash{String => Object}>] the fused result rows
        # @return [Integer, nil] the total number of fused results
        # @return [Array] any warnings returned by the server
        # @return [Float, nil] the server-side execution time
        # @return [Integer, nil] the SEARCH-leg cursor id (WITHCURSOR only)
        # @return [Integer, nil] the VSIM-leg cursor id (WITHCURSOR only)
        attr_reader :rows, :total, :warnings, :execution_time, :search_cursor, :vsim_cursor

        def initialize(rows: [], total: nil, warnings: [], execution_time: nil,
                       search_cursor: nil, vsim_cursor: nil)
          @rows = rows
          @total = total
          @warnings = warnings
          @execution_time = execution_time
          @search_cursor = search_cursor
          @vsim_cursor = vsim_cursor
        end

        # Iterate over the result rows.
        #
        # @yieldparam row [Hash{String => Object}]
        # @return [Enumerator, Array<Hash>]
        def each(&block)
          @rows.each(&block)
        end

        # @param index [Integer] the row position
        # @return [Hash, nil] the row at +index+, or nil when out of range
        def [](index)
          @rows[index]
        end

        # @return [Integer] the number of rows
        def size
          @rows.size
        end
        alias length size

        # @return [Boolean] whether there are no rows
        def empty?
          @rows.empty?
        end

        # @return [Boolean] whether this is a WITHCURSOR reply carrying cursor ids
        def cursor?
          !@search_cursor.nil? || !@vsim_cursor.nil?
        end
      end

      # Reply reshaping for the Query Engine.
      #
      # Every parser normalises *both* RESP2 (flat arrays) and RESP3 (native maps) replies to
      # the same Ruby objects, so the public API is stable regardless of the protocol the
      # underlying connection negotiates. RESP3 is the default protocol; the RESP2 branches exist
      # for +protocol: 2+ connections.
      module ResultParser
        module_function

        # FT.SEARCH -> SearchResult
        #
        # @param reply [Array, Hash] RESP2 flat array or RESP3 map
        # @param with_scores [Boolean] WITHSCORES was set (RESP2 only; RESP3 carries it inline)
        # @param with_payloads [Boolean] WITHPAYLOADS was set (RESP2 only)
        # @param no_content [Boolean] NOCONTENT was set
        # @param decode_fields [Hash] field name => whether to JSON-decode its value
        # @return [SearchResult, nil] the parsed result (nil when +reply+ is nil)
        def search(reply, with_scores: false, with_payloads: false, no_content: false, decode_fields: {})
          return reply if reply.nil?

          if reply.is_a?(Hash) # RESP3
            search_resp3(reply, decode_fields)
          else # RESP2 flat array
            search_resp2(reply, with_scores, with_payloads, no_content, decode_fields)
          end
        end

        # Parse a RESP2 flat-array FT.SEARCH reply into a {SearchResult}.
        #
        # @param reply [Array] the flat +[total, id, ..., fields, ...]+ array
        # @param with_scores [Boolean] WITHSCORES was set
        # @param with_payloads [Boolean] WITHPAYLOADS was set
        # @param no_content [Boolean] NOCONTENT was set
        # @param decode_fields [Hash] field name => whether to JSON-decode its value
        # @return [SearchResult]
        def search_resp2(reply, with_scores, with_payloads, no_content, decode_fields)
          total = reply[0]
          documents = []
          index = 1

          while index < reply.length
            id = reply[index]
            index += 1

            score = nil
            if with_scores
              score = normalize_score(reply[index])
              index += 1
            end

            payload = nil
            if with_payloads
              payload = reply[index]
              index += 1
            end

            attributes = {}
            unless no_content
              attributes = hashify_fields(reply[index], decode_fields)
              index += 1
            end

            documents << Document.new(id, attributes: attributes, score: score, payload: payload)
          end

          SearchResult.new(total, documents)
        end

        # Parse a RESP3 map FT.SEARCH reply into a {SearchResult}.
        #
        # @param reply [Hash] the native map carrying +"results"+ and +"total_results"+
        # @param decode_fields [Hash] field name => whether to JSON-decode its value
        # @return [SearchResult]
        def search_resp3(reply, decode_fields)
          documents = (reply["results"] || []).map do |row|
            attributes = hashify_fields(row["extra_attributes"], decode_fields)
            Document.new(row["id"], attributes: attributes, score: normalize_score(row["score"]),
                                    payload: row["payload"])
          end

          SearchResult.new(reply["total_results"], documents)
        end

        # FT.AGGREGATE / FT.CURSOR READ -> AggregateResult
        #
        # Without a cursor the reply is [num_rows, row, row, ...] (RESP2) or a map with
        # "results" (RESP3). With WITHCURSOR the reply is [aggregate_reply, cursor_id].
        #
        # @param reply [Array, Hash] the FT.AGGREGATE / FT.CURSOR READ reply
        # @return [AggregateResult, nil] the parsed result (nil when +reply+ is nil)
        def aggregate(reply)
          return reply if reply.nil?

          cursor = nil
          body = reply
          # WITHCURSOR wraps the aggregate body and the cursor id in a 2-element array. The
          # body is a flat array under RESP2 and a native map under RESP3.
          if reply.is_a?(Array) && reply.length == 2 && reply[1].is_a?(Integer) &&
             (reply[0].is_a?(Array) || reply[0].is_a?(Hash))
            body = reply[0]
            cursor = reply[1]
          end

          rows =
            if body.is_a?(Hash) # RESP3
              (body["results"] || []).map { |row| hashify_fields(row["extra_attributes"] || row, {}) }
            else # RESP2: first element is the row count, the rest are rows
              body[1..-1].to_a.map { |row| hashify_fields(row, {}) }
            end

          AggregateResult.new(rows, cursor: cursor)
        end

        # FT.HYBRID -> HybridResult
        #
        # The reply is a native map under RESP3 and a flat [k, v, ...] array under RESP2. A
        # WITHCURSOR reply carries per-leg cursor ids ("SEARCH"/"VSIM") instead of a result page.
        #
        # @param reply [Array, Hash] the FT.HYBRID reply
        # @return [HybridResult, nil] the parsed result (nil when +reply+ is nil)
        def hybrid(reply)
          return reply if reply.nil?

          map = reply.is_a?(Hash) ? reply : Hash[*reply]

          if map.key?("SEARCH") || map.key?("VSIM")
            return HybridResult.new(
              warnings: map["warnings"] || [],
              search_cursor: map["SEARCH"],
              vsim_cursor: map["VSIM"]
            )
          end

          rows = Array(map["results"]).map { |row| hashify_fields(row, {}) }
          HybridResult.new(
            rows: rows,
            total: map["total_results"],
            warnings: map["warnings"] || [],
            execution_time: map["execution_time"]
          )
        end

        # FT.INFO / FT.CONFIG GET -> Hash. RESP2 returns a flat [k, v, ...] array; RESP3
        # already returns a native map.
        #
        # @param reply [Array, Hash] the FT.INFO reply
        # @return [Hash, nil] the info as a hash (nil when +reply+ is nil)
        def hashify_info(reply)
          return reply if reply.nil?
          return reply if reply.is_a?(Hash)

          Hash[*reply]
        end

        # FT.CONFIG GET -> Hash. RESP2 returns nested [[option, value], ...] pairs; RESP3 a map.
        #
        # @param reply [Array, Hash] the FT.CONFIG GET reply
        # @return [Hash, nil] option => value (nil when +reply+ is nil)
        def config_get(reply)
          return reply if reply.nil?
          return reply if reply.is_a?(Hash)

          reply.to_h
        end

        # FT.SYNDUMP -> { term => [group_id, ...] }. RESP2 is a flat [term, [ids], ...] array.
        #
        # @param reply [Array, Hash] the FT.SYNDUMP reply
        # @return [Hash{String => Array}, nil] term => group ids (nil when +reply+ is nil)
        def syndump(reply)
          return reply if reply.nil?
          return reply if reply.is_a?(Hash)

          Hash[*reply]
        end

        # FT.SPELLCHECK -> { term => [{ "suggestion" => ..., "score" => ... }, ...] }
        #
        # @param reply [Array, Hash] the FT.SPELLCHECK reply
        # @return [Hash{String => Array<Hash>}, nil] term => suggestions (nil when +reply+ is nil)
        def spellcheck(reply)
          return reply if reply.nil?

          # RESP3: { "results" => { term => [{ suggestion => score }, ...] } }
          if reply.is_a?(Hash)
            results = reply["results"] || {}
            return results.each_with_object({}) do |(term, suggestions), acc|
              acc[term] = suggestions.flat_map do |entry|
                entry.map { |suggestion, score| { "suggestion" => suggestion, "score" => score } }
              end
            end
          end

          # RESP2: [["TERM", term, [[score, suggestion], ...]], ...]
          parsed = {}
          reply.each do |entry|
            next unless entry[0] == "TERM"

            parsed[entry[1]] = entry[2].map do |score, suggestion|
              { "suggestion" => suggestion, "score" => score }
            end
          end
          parsed
        end

        # Turn a flat [field, value, ...] array (RESP2) or a native map (RESP3) of returned
        # fields into a hash, JSON-decoding values whose field is flagged in +decode_fields+.
        #
        # @param fields [Array, Hash, nil] the field/value pairs
        # @param decode_fields [Hash] field name => whether to JSON-decode its value
        # @return [Hash{String => Object}] the fields as a hash (empty when +fields+ is nil)
        # Normalize a WITHSCORES value to a Float so Document#score is the same type regardless of
        # protocol (RESP2 returns the score as a bulk string, RESP3 as a native double). With
        # EXPLAINSCORE the RESP2 value is +[score, explanation]+; coerce the score part and keep
        # the explanation. Anything non-numeric is returned untouched.
        def normalize_score(score)
          case score
          when nil then nil
          when Array then [normalize_score(score[0]), *score[1..]]
          else Float(score)
          end
        rescue ArgumentError, TypeError
          score
        end

        def hashify_fields(fields, decode_fields)
          return {} if fields.nil?

          # Reply field names are strings, but callers may key decode_fields with symbols
          # (e.g. Query#return_field(:brand)). Normalize so decoding is caller-type-independent.
          decode = decode_fields.transform_keys(&:to_s)
          pairs = fields.is_a?(Hash) ? fields.to_a : fields.each_slice(2).to_a

          pairs.each_with_object({}) do |(name, value), acc|
            acc[name] = decode[name.to_s] ? decode_value(value) : value
          end
        end

        # JSON-decode a value, returning it unchanged when it is not a parseable JSON String.
        #
        # @param value [Object] the value to decode
        # @return [Object] the parsed value, or +value+ when it is not a String or fails to parse
        def decode_value(value)
          return value unless value.is_a?(String)

          ::JSON.parse(value)
        rescue ::JSON::ParserError
          value
        end
      end
    end
  end
end
