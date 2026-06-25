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
        # @return [String, nil] the key prefix indexed/added documents live under
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
          new(redis, name, schema, storage_type, prefix: prefix, stopwords: stopwords)
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
          key = @prefix ? "#{@prefix}:#{doc_id}" : doc_id

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

          # Apply keyword argument options to the query
          query.no_content if nocontent
          query.verbatim if verbatim
          query.no_stopwords if no_stopwords
          query.with_scores if with_scores
          query.with_payloads if with_payloads
          query.slop(slop) if slop
          query.in_order if in_order
          query.language(language) if language
          query.scorer(scorer) if scorer
          query.explain_score if explain_score
          query.return_fields = return_fields if return_fields
          query.summarize_options = summarize if summarize
          query.highlight_options = highlight if highlight

          if sort_by
            order = asc == false ? "DESC" : "ASC"
            query.options[:sortby] = [sort_by, order]
          end

          redis_args = query.to_redis_args
          query_string = redis_args.shift

          options = query.options
          options[:filter] = query.filters
          options[:geo_filter] = query.geo_filters

          # Add prefix to limit_ids if a prefix is set
          options[:limit_ids] = if query.limit_ids_value && @prefix
            query.limit_ids_value.map { |id| "#{@prefix}:#{id}" }
          else
            query.limit_ids_value
          end

          options[:sortby] = query.options[:sortby]

          # Get dialect from query options or method parameter
          query_dialect = query.options[:dialect]
          options[:dialect] = dialect || query_dialect

          options[:params] = params if params

          options[:return] = query.return_fields
          options[:decode_fields] = query.return_fields_decode

          options[:highlight] = query.highlight_options
          options[:summarize] = query.summarize_options
          options[:verbatim] = query.verbatim_value
          options[:no_stopwords] = query.no_stopwords_value
          options[:no_content] = query.no_content_value
          options[:with_scores] = query.options[:withscores]
          options[:scorer] = query.options[:scorer]
          options[:explain_score] = query.options[:explainscore]
          options[:language] = query.language_value
          options[:with_payloads] = query.with_payloads_value
          options[:slop] = query.slop_value
          options[:in_order] = query.in_order_value
          options[:timeout] = query.timeout_value
          options[:limit_fields] = query.limit_fields_value
          options[:expander] = query.expander_value

          if query_params
            options[:params] = query_params
          end

          result = @redis.ft_search(@name, query_string, **options)

          # Strip the index prefix from document IDs if one is set, so callers see the
          # logical doc id they passed to #add rather than the underlying Redis key.
          if @prefix && result.is_a?(SearchResult)
            prefix = "#{@prefix}:"
            result.documents.map! do |doc|
              next doc unless doc.id.is_a?(String) && doc.id.start_with?(prefix)

              Document.new(
                doc.id.delete_prefix(prefix),
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
        # @param args [Array] a {Field} or raw token array describing the field to add
        # @return [String] +"OK"+
        def alter(*args)
          @redis.ft_alter(@name, *args)
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
