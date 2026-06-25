# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # High-level handle to a search index: a {Schema}, an optional key prefix and a +Redis+
      # connection bundled together. It is the most ergonomic entry point for HASH/JSON document
      # workflows — it remembers the prefix (so document ids round-trip to the logical id passed to
      # {#add}), validates field values against the schema, and accepts a {Query}, a query string,
      # or a block in {#search}. Obtain one via +Redis#create_index+ or {Index.create}.
      class Index
        # @return [String] the index name
        # @return [String, nil] the literal key prefix prepended to (and stripped from) document
        #   ids, e.g. "doc:"; nil when the index manages no single prefix
        attr_reader :name, :prefix

        # @param redis [Redis] the client used for all index operations
        # @param name [String] the index name
        # @param schema [Schema] the field schema
        # @param storage_type [String] the indexed data type (+"hash"+ or +"json"+)
        # @param prefix [String, nil] key prefix for documents
        # @param stopwords [Array<String>, nil] custom stopword list
        def initialize(redis, name, schema, storage_type, prefix: nil, stopwords: nil)
          @redis = redis
          @name = name
          @prefix = prefix
          @schema = schema
          @storage_type = storage_type
          @stopwords = stopwords
        end

        # Create the index on the server (runs +FT.CREATE+) and return a handle to it.
        #
        # @example
        #   Redis::Commands::Search::Index.create(redis, "idx", schema, "hash", prefix: "doc")
        #
        # @param redis [Redis] the client to use
        # @param name [String] the index name
        # @param schema [Schema] the field schema
        # @param storage_type [String] the indexed data type (+"hash"+ or +"json"+)
        # @param prefix [String, nil] key prefix for documents
        # @param stopwords [Array<String>, nil] custom stopword list
        # @param skip_initial_scan [Boolean] do not backfill existing keys (+SKIPINITIALSCAN+)
        # @return [Index] the created index
        # @raise [ArgumentError] if +schema+ is not a {Schema}
        def self.create(
          redis, name, schema, storage_type,
          prefix: nil, stopwords: nil, skip_initial_scan: false, **options
        )
          raise ArgumentError, "Invalid schema" unless schema.is_a?(Schema)

          redis.ft_create(
            name, schema, storage_type,
            prefix: prefix, stopwords: stopwords,
            skip_initial_scan: skip_initial_scan, **options
          )
          # The Index stores the *literal* key prefix it prepends to (and strips from) document
          # ids. A definition (which FT.CREATE prefers over the +prefix:+ keyword) carries its
          # prefixes verbatim, e.g. "bicycle:"; the +prefix:+ keyword form appends the ":".
          new(
            redis, name, schema, storage_type,
            prefix: key_prefix(prefix, options[:definition]), stopwords: stopwords
          )
        end

        # The single literal key prefix the Index should manage, or nil when it can't be
        # determined unambiguously (no prefix, or a definition with several prefixes).
        def self.key_prefix(prefix, definition)
          if definition.is_a?(IndexDefinition) && definition.prefixes.size == 1
            definition.prefixes.first
          elsif prefix
            "#{prefix}:"
          end
        end

        # Add (or replace) a document by writing its fields to the underlying HASH key
        # (+"<prefix>:<doc_id>"+ when a prefix is set, otherwise +doc_id+).
        #
        # @example
        #   index.add("1", title: "hello", price: 10)
        #
        # @param doc_id [String] the logical document id
        # @param fields [Hash{Symbol,String => Object}] the field/value pairs to store
        # @return [Integer] the number of fields that were newly added (the +HSET+ reply)
        # @raise [Redis::CommandError] if a value for a {NumericField} is not Numeric, or the write fails
        def add(doc_id, **fields)
          key = @prefix ? "#{@prefix}#{doc_id}" : doc_id

          # Validate fields
          fields.each do |field_name, value|
            field = @schema.field(field_name)
            if field.is_a?(NumericField) && !value.is_a?(Numeric)
              raise Redis::CommandError, "Invalid value for numeric field '#{field_name}': #{value}"
            end
          end

          begin
            @redis.hset(key, fields)
          rescue Redis::CommandError => error
            raise Redis::CommandError, "Error adding document: #{error.message}"
          end
        end

        # Search the index.
        #
        # Accepts a {Query} object, a raw query string, or a block evaluated as a {Query}. Keyword
        # arguments are applied on top of the query before it is sent. Document ids in the result
        # have the index prefix stripped, so they match the ids passed to {#add}.
        #
        # @example with a Query object
        #   index.search(Redis::Commands::Search::Query.new("@title:hello").paging(0, 10))
        #
        # @example with a block
        #   index.search { text(:title).match("hello*") }
        #
        # @param query [Query, String, nil] the query (a {Query}, a query string, or nil when a
        #   block is given)
        # @param query_params [Hash, Array, nil] query parameter substitutions (overrides +params+)
        # @param params [Hash, Array, nil] query parameter substitutions (+PARAMS+)
        # @param dialect [Integer, nil] query dialect version (+DIALECT+)
        # @param nocontent [Boolean, nil] return ids only (+NOCONTENT+)
        # @param verbatim [Boolean, nil] disable stemming (+VERBATIM+)
        # @param no_stopwords [Boolean, nil] do not remove stopwords (+NOSTOPWORDS+)
        # @param with_scores [Boolean, nil] include relevance scores (+WITHSCORES+)
        # @param with_payloads [Boolean, nil] include payloads (+WITHPAYLOADS+)
        # @param slop [Integer, nil] allowed term reordering distance (+SLOP+)
        # @param in_order [Boolean, nil] require terms in query order (+INORDER+)
        # @param language [String, nil] stemming language (+LANGUAGE+)
        # @param return_fields [Array<String>, nil] only return these fields (+RETURN+)
        # @param summarize [Hash, nil] +SUMMARIZE+ options
        # @param highlight [Hash, nil] +HIGHLIGHT+ options
        # @param sort_by [String, nil] sort field (+SORTBY+)
        # @param asc [Boolean, nil] sort ascending (default) when +sort_by+ is given; +false+ for descending
        # @param scorer [String, nil] scoring function name (+SCORER+)
        # @param explain_score [Boolean, nil] include a score explanation (+EXPLAINSCORE+)
        # @return [SearchResult] the total count and matching {Document}s (prefix stripped from ids)
        # @raise [ArgumentError] if no usable query is provided
        def search(query = nil, query_params: nil, params: nil, dialect: nil,
                   nocontent: nil, verbatim: nil, no_stopwords: nil, with_scores: nil,
                   with_payloads: nil, slop: nil, in_order: nil, language: nil,
                   return_fields: nil, summarize: nil, highlight: nil, sort_by: nil, asc: nil,
                   scorer: nil, explain_score: nil, &block)
          if block_given?
            query = Query.build(&block)
          elsif query.is_a?(String)
            query = Query.new(query)
          end

          raise ArgumentError, "Invalid query" unless query.is_a?(Query)

          query_string = query.to_redis_args.first

          sort_order = asc == false ? "DESC" : "ASC"
          sortby = sort_by ? [sort_by, sort_order] : query.options[:sortby]
          limit_ids = query.limit_ids_value
          limit_ids = limit_ids.map { |id| "#{@prefix}#{id}" } if limit_ids && @prefix

          # An empty RETURN list is not a meaningful per-call value (it would just omit RETURN and
          # return all fields), so treat it as "unset" and fall back to the Query's RETURN list.
          return_fields = nil if return_fields.is_a?(Array) && return_fields.empty?

          # Build a fresh options hash per call. A per-call keyword argument wins when explicitly
          # given (including +false+, to turn a flag off); +nil+ falls back to whatever the Query
          # was built with. The Query is never mutated, so reusing one Query across searches never
          # leaks options between calls and per-call flags can both enable and disable.
          pick = ->(call_value, query_value) { call_value.nil? ? query_value : call_value }

          options = {
            filter: query.filters,
            geo_filter: query.geo_filters,
            limit_ids: limit_ids,
            limit: query.options[:limit],
            sortby: sortby,
            dialect: pick.call(dialect, query.options[:dialect]),
            return: pick.call(return_fields, query.return_fields),
            decode_fields: query.return_fields_decode,
            highlight: pick.call(highlight, query.highlight_options),
            summarize: pick.call(summarize, query.summarize_options),
            verbatim: pick.call(verbatim, query.verbatim_value),
            no_stopwords: pick.call(no_stopwords, query.no_stopwords_value),
            no_content: pick.call(nocontent, query.no_content_value),
            with_scores: pick.call(with_scores, query.options[:withscores]),
            scorer: pick.call(scorer, query.options[:scorer]),
            explain_score: pick.call(explain_score, query.options[:explainscore]),
            language: pick.call(language, query.language_value),
            with_payloads: pick.call(with_payloads, query.with_payloads_value),
            slop: pick.call(slop, query.slop_value),
            in_order: pick.call(in_order, query.in_order_value),
            timeout: query.timeout_value,
            limit_fields: query.limit_fields_value,
            expander: query.expander_value
          }
          substitutions = query_params || params
          options[:params] = substitutions if substitutions

          result = @redis.ft_search(@name, query_string, **options)

          # Strip the index prefix from document IDs if one is set, so callers see the
          # logical doc id they passed to #add rather than the underlying Redis key.
          if @prefix && result.is_a?(SearchResult)
            result.documents.map! do |doc|
              next doc unless doc.id.is_a?(String) && doc.id.start_with?(@prefix)

              Document.new(
                doc.id.delete_prefix(@prefix),
                attributes: doc.attributes, score: doc.score, payload: doc.payload
              )
            end
          end

          result
        end

        # Return information and statistics about the index (delegates to +FT.INFO+).
        #
        # @return [Hash] index metadata
        def info
          @redis.ft_info(@name)
        end

        # Drop the index (delegates to +FT.DROPINDEX+).
        #
        # @param delete_documents [Boolean] also delete the indexed documents (+DD+)
        # @return [String] +"OK"+
        def drop(delete_documents: false)
          @redis.ft_dropindex(@name, delete_documents: delete_documents)
        end

        # Run an aggregation pipeline against the index (delegates to +FT.AGGREGATE+).
        #
        # @param query [AggregateRequest, Cursor, String] the aggregate request, a cursor, or a raw
        #   query string followed by raw pipeline +args+
        # @param args [Array] raw pipeline tokens when +query+ is a String
        # @return [AggregateResult] the result rows and cursor
        def aggregate(query, *args)
          @redis.ft_aggregate(@name, query, *args)
        end

        # Run a hybrid (lexical + vector) search against this index (delegates to +FT.HYBRID+).
        #
        # @param query [Search::HybridQuery] the combined SEARCH + VSIM query
        # @param combine_method [Search::CombineResultsMethod, nil] the fusion strategy (RRF/LINEAR)
        # @param post_processing [Search::HybridPostProcessingConfig, nil] a post-fusion pipeline
        # @param params_substitution [Hash, nil] query parameter substitutions (+PARAMS+)
        # @param timeout [Integer, nil] query timeout in milliseconds (+TIMEOUT+)
        # @param cursor [Search::HybridCursorQuery, nil] cursor/pagination config (+WITHCURSOR+)
        # @return [Search::HybridResult] the fused results (or per-leg cursor ids for WITHCURSOR)
        def hybrid_search(query:, combine_method: nil, post_processing: nil,
                          params_substitution: nil, timeout: nil, cursor: nil)
          @redis.ft_hybrid_search(
            @name,
            query: query, combine_method: combine_method, post_processing: post_processing,
            params_substitution: params_substitution, timeout: timeout, cursor: cursor
          )
        end

        # Return the execution plan for a query without running it (delegates to +FT.EXPLAIN+).
        #
        # @param query [String] the query string
        # @return [String] the query plan
        def explain(query)
          @redis.ft_explain(@name, query)
        end

        # Add a field to the index schema (delegates to +FT.ALTER+).
        #
        # @param field_or_args [Search::Field, Array] a {Search::Field} (rendered via +#to_args+)
        #   or a raw token array describing the field to add
        # @return [String] +"OK"+
        def alter(field_or_args)
          @redis.ft_alter(@name, field_or_args)
        end

        # Perform spelling correction over a query against the index (delegates to +FT.SPELLCHECK+).
        #
        # @param query [String] the query whose terms are checked
        # @param args [Array] additional spellcheck arguments
        # @return [Hash{String=>Array<Hash>}] misspelled terms mapped to suggestions
        def spellcheck(query, *args)
          @redis.ft_spellcheck(@name, query, *args)
        end

        # Add or update a synonym group on the index (delegates to +FT.SYNUPDATE+).
        #
        # @param group_id [String] the synonym group id
        # @param terms [Array<String>] the terms to add to the group
        # @param skip_initial_scan [Boolean] do not re-scan existing documents (+SKIPINITIALSCAN+)
        # @return [String] +"OK"+
        def synupdate(group_id, *terms, skip_initial_scan: false)
          @redis.ft_synupdate(@name, group_id, *terms, skip_initial_scan: skip_initial_scan)
        end

        # Dump the synonym groups of the index (delegates to +FT.SYNDUMP+).
        #
        # @return [Hash{String=>Array<String>}] each term mapped to its synonym group ids
        def syndump
          @redis.ft_syndump(@name)
        end

        # List the distinct values of a TAG field (delegates to +FT.TAGVALS+).
        #
        # @param field_name [String] the TAG field name
        # @return [Array<String>] the distinct tag values
        def tagvals(field_name)
          @redis.ft_tagvals(@name, field_name)
        end

        # Profile the execution of a query (delegates to +FT.PROFILE+).
        #
        # @param args [Array] the profile arguments
        # @return [Array] the raw profile reply
        def profile(*args)
          @redis.ft_profile(@name, *args)
        end

        private

        def create_from_schema(schema)
          @redis.ft_create(@name, schema)
        end
      end
    end
  end
end
