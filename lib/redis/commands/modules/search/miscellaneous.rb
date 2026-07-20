# frozen_string_literal: true

class Redis
  module Commands
    # Redis Query Engine (RediSearch, the +FT.*+ command family). See
    # {file:specs/query-engine.md} for the layered design and an abstractions-vs-raw-commands guide.
    #
    # Replies are reshaped by {Search::ResultParser} into {Search::SearchResult} /
    # {Search::Document} (for +FT.SEARCH+), {Search::AggregateResult} (for +FT.AGGREGATE+ /
    # +FT.CURSOR READ+), or plain Hashes/Arrays. Reshaping is identical under RESP2 and RESP3.
    module Search
      # Create a search index over HASH or JSON keys.
      #
      # @example
      #   schema = Redis::Commands::Search::Schema.build { text_field :title }
      #   redis.ft_create("idx", schema, prefix: "doc")
      #     # => "OK"
      #
      # @param index_name [String] the index name
      # @param schema [Search::Schema] the field schema; the +SCHEMA+ clause is rendered from it
      # @param storage_type [String, Symbol, nil] the data type to index, e.g. +"HASH"+ or +"JSON"+
      #   (emitted as +ON <type>+); ignored when +definition+ is given
      # @param prefix [String, nil] index keys whose name starts with +"<prefix>:"+; ignored when
      #   +definition+ is given
      # @param stopwords [Array<String>, nil] a custom stopword list (emits +STOPWORDS+)
      # @param max_text_fields [Boolean] emit +MAXTEXTFIELDS+
      # @param skip_initial_scan [Boolean] emit +SKIPINITIALSCAN+ (do not backfill existing keys)
      # @param definition [Search::IndexDefinition, nil] a prebuilt +ON .../PREFIX/FILTER/...+ clause;
      #   when given it takes precedence over +storage_type+/+prefix+
      # @param temporary [Integer, nil] index lifetime in seconds (emits +TEMPORARY <seconds>+)
      # @param no_term_offsets [Boolean] emit +NOOFFSETS+
      # @param no_highlight [Boolean] emit +NOHL+
      # @param no_field_flags [Boolean] emit +NOFIELDS+
      # @param no_term_frequencies [Boolean] emit +NOFREQS+
      # @return [String] +"OK"+
      # @raise [ArgumentError] if +schema+ is not a {Search::Schema}
      def ft_create(
        index_name, schema, storage_type = nil,
        prefix: nil, stopwords: nil, max_text_fields: false,
        skip_initial_scan: false, definition: nil, temporary: nil,
        no_term_offsets: false, no_highlight: false,
        no_field_flags: false, no_term_frequencies: false, **_options
      )
        raise ArgumentError, "schema must be a Schema object" unless schema.is_a?(Schema)

        args = [index_name]

        # Use IndexDefinition if provided, otherwise use legacy parameters
        if definition
          # The definition supplies the ON/PREFIX/FILTER clause. When it doesn't declare an index
          # type, fall back to the storage_type keyword so e.g. a JSON index isn't silently created
          # as HASH. Normalize to the uppercase HASH/JSON form some Query Engine versions require.
          args += ["ON", storage_type.to_s.upcase] if definition.index_type.nil? && storage_type
          args += definition.args
        else
          # Normalize the ON token to HASH/JSON; a lowercase value is rejected by some
          # Query Engine versions (and IndexType/the docs use the uppercase form).
          args += ["ON", storage_type.to_s.upcase] if storage_type
          args += ["PREFIX", 1, "#{prefix}:"] if prefix
        end

        args << "MAXTEXTFIELDS" if max_text_fields

        if temporary
          args << "TEMPORARY"
          args << temporary
        end

        args << "NOOFFSETS" if no_term_offsets
        args << "NOHL" if no_highlight
        args << "NOFIELDS" if no_field_flags
        args << "NOFREQS" if no_term_frequencies
        args << "SKIPINITIALSCAN" if skip_initial_scan

        # Stopwords
        if stopwords
          args += ['STOPWORDS', stopwords.size]
          stopwords.each do |stopword|
            args << stopword
          end
        end

        # Schema Fields
        args += ["SCHEMA"]
        schema.fields.each do |field|
          args += field.to_args
        end

        send_command([:"FT.CREATE", *args])
      end

      # Create an index and return a high-level {Search::Index} bound to this client.
      #
      # Unlike {#ft_create} (which returns +"OK"+), this returns a stateful {Search::Index} that
      # remembers the schema and prefix and exposes +#add+/+#search+/+#aggregate+/etc.
      #
      # @example
      #   index = redis.create_index("idx", schema, prefix: "doc")
      #   index.add("1", title: "hello")
      #   index.search("hello").total # => 1
      #
      # @param name [String] the index name
      # @param schema [Search::Schema] the field schema
      # @param storage_type [String] the data type to index (+"hash"+ or +"json"+)
      # @param prefix [String, nil] key prefix for indexed/added documents
      # @param stopwords [Array<String>, nil] custom stopword list
      # @param max_text_fields [Boolean] emit +MAXTEXTFIELDS+
      # @param skip_initial_scan [Boolean] emit +SKIPINITIALSCAN+
      # @param definition [Search::IndexDefinition, nil] prebuilt index definition clause
      # @return [Search::Index] the created index
      # @raise [Redis::CommandError] if +schema+ is not a {Search::Schema} or creation fails
      def create_index(
        name, schema, storage_type: "hash",
        prefix: nil, stopwords: nil, max_text_fields: false,
        skip_initial_scan: false, definition: nil, **options
      )
        raise Redis::CommandError, "schema must be a Schema object" unless schema.is_a?(Schema)

        begin
          Index.create(
            self, name, schema, storage_type,
            prefix: prefix, stopwords: stopwords,
            max_text_fields: max_text_fields,
            skip_initial_scan: skip_initial_scan,
            definition: definition, **options
          )
        rescue ArgumentError => e
          raise Redis::CommandError, e.message
        end
      end

      # Search an index.
      #
      # @example
      #   redis.ft_search("idx", "@title:hello", limit: [0, 10], with_scores: true)
      #     # => #<SearchResult total=1 ...>
      #
      # @example raw vector (KNN) query
      #   redis.ft_search("idx", "(*)=>[KNN 2 @vec $v]", params: { v: blob }, dialect: 2)
      #
      # @param index_name [String] the index (or alias) name
      # @param query [String] the query string (use {Search::Query}+#to_redis_args.first+ to build one)
      # @param options [Hash] search options translated to +FT.SEARCH+ tokens
      # @option options [Boolean] :no_content return ids only (+NOCONTENT+); documents have no fields
      # @option options [Boolean] :verbatim disable stemming (+VERBATIM+)
      # @option options [Boolean] :no_stopwords do not remove stopwords (+NOSTOPWORDS+)
      # @option options [Boolean] :with_scores include the relevance score on each document (+WITHSCORES+)
      # @option options [Boolean] :with_payloads include each document's payload (+WITHPAYLOADS+)
      # @option options [String] :scorer scoring function name (+SCORER+), e.g. +"BM25"+/+"TFIDF"+
      # @option options [Boolean] :explain_score include a score explanation (+EXPLAINSCORE+)
      # @option options [String] :language stemming language (+LANGUAGE+)
      # @option options [Integer] :slop allowed term reordering distance (+SLOP+)
      # @option options [Boolean] :in_order require terms in query order (+INORDER+)
      # @option options [Integer] :timeout per-query timeout in milliseconds (+TIMEOUT+)
      # @option options [String] :expander custom query expander (+EXPANDER+)
      # @option options [Array<String>] :limit_fields restrict full-text matching to these fields (+INFIELDS+)
      # @option options [Array(Integer, Integer)] :limit +[offset, count]+ paging (+LIMIT+)
      # @option options [Array(String, String)] :sortby +[field, "ASC"|"DESC"]+ (+SORTBY+)
      # @option options [String] :sort_by sort field (convenience; pair with +:asc+)
      # @option options [Boolean] :asc sort ascending when +:sort_by+ is used (default; pass
      #   +false+ for descending)
      # @option options [Array<Array>] :filter numeric filters, each +[field, min, max]+ (+FILTER+)
      # @option options [Array<Array>] :geo_filter geo filters, each +[field, lon, lat, radius, unit]+
      # @option options [Array<String>] :limit_ids restrict to these keys (+INKEYS+)
      # @option options [Array<String>] :return only return these fields (+RETURN+)
      # @option options [Hash] :summarize +SUMMARIZE+ options (+:fields+, +:frags+, +:len+, +:separator+)
      # @option options [Hash] :highlight +HIGHLIGHT+ options (+:fields+, +:tags+)
      # @option options [Hash, Array] :params query parameter substitutions (+PARAMS+)
      # @option options [Integer] :dialect query dialect version (+DIALECT+)
      # @option options [Hash{String=>Boolean}] :decode_fields field name => whether to JSON-decode its
      #   value in the returned {Search::Document}
      # @return [Search::SearchResult] the total count and the matching {Search::Document}s
      def ft_search(index_name, query, **options)
        args = [index_name, query]

        args << "NOCONTENT" if options[:no_content]
        args << "VERBATIM" if options[:verbatim]
        args << "NOSTOPWORDS" if options[:no_stopwords]
        # EXPLAINSCORE requires WITHSCORES, so emit WITHSCORES whenever an explanation is asked for.
        args << "WITHSCORES" if options[:with_scores] || options[:explain_score]
        args << "WITHPAYLOADS" if options[:with_payloads]
        args << "SCORER" << options[:scorer] if options[:scorer]
        args << "EXPLAINSCORE" if options[:explain_score]
        args << "LANGUAGE" << options[:language] if options[:language]
        args << "SLOP" << options[:slop] if options[:slop]
        args << "INORDER" if options[:in_order]
        args << "TIMEOUT" << options[:timeout] if options[:timeout]
        args << "EXPANDER" << options[:expander] if options[:expander]
        if options[:limit_fields] && !options[:limit_fields].empty?
          args << "INFIELDS" << options[:limit_fields].size
          args.concat(options[:limit_fields].map(&:to_s))
        end
        args << "LIMIT" << options[:limit][0] << options[:limit][1] if options[:limit]

        # Handle both :sortby (array format) and :sort_by (convenience format)
        if options[:sortby]
          args << "SORTBY" << options[:sortby][0] << options[:sortby][1]
        elsif options[:sort_by]
          # Default to ASC when :asc is omitted (matching Index#search, Query#sort_by and the
          # server's own SORTBY default); only an explicit asc: false sorts descending.
          direction = options[:asc] == false ? 'DESC' : 'ASC'
          args << "SORTBY" << options[:sort_by] << direction
        end

        options[:filter]&.each do |field, min, max|
          args << "FILTER" << field << min << max
        end

        options[:geo_filter]&.each do |field, lon, lat, radius, unit|
          args << "GEOFILTER" << field << lon << lat << radius << unit
        end

        if options[:limit_ids] && !options[:limit_ids].empty?
          args << "INKEYS" << options[:limit_ids].size
          args.concat(options[:limit_ids])
        end

        if options[:return] && !options[:return].empty?
          args << "RETURN" << options[:return].size
          args.concat(options[:return])
        end

        if options[:summarize]
          args << "SUMMARIZE"
          if options[:summarize][:fields]&.any?
            args << "FIELDS" << options[:summarize][:fields].size
            args.concat(options[:summarize][:fields].map(&:to_s))
          end
          args << "FRAGS" << options[:summarize][:frags] if options[:summarize][:frags]
          args << "LEN" << options[:summarize][:len] if options[:summarize][:len]
          args << "SEPARATOR" << options[:summarize][:separator] if options[:summarize][:separator]
        end

        if options[:highlight]
          args << "HIGHLIGHT"
          if options[:highlight][:fields]&.any?
            args << "FIELDS" << options[:highlight][:fields].size
            args.concat(options[:highlight][:fields].map(&:to_s))
          end
          if options[:highlight][:tags]
            args << "TAGS" << options[:highlight][:tags][0] << options[:highlight][:tags][1]
          end
        end

        if options[:params]
          if options[:params].is_a?(Hash)
            args << "PARAMS" << (options[:params].length * 2)
            options[:params].each do |k, v|
              args << k.to_s << v
            end
          else
            args << "PARAMS" << options[:params].length
            args.concat(options[:params])
          end
        end

        # Default to DIALECT 2 (matching redis-py) unless the caller specified one. An explicit
        # dialect: nil (e.g. flowing from an unset Query option) falls back to the default too, so
        # it behaves the same as omitting the keyword rather than deferring to the server default.
        dialect = options[:dialect] || DEFAULT_DIALECT
        args << "DIALECT" << dialect

        # WITHSCORES is emitted for explain_score too (EXPLAINSCORE requires it), so the RESP2
        # parser must expect a score column in the same cases or it mis-reads the reply layout.
        with_scores = options[:with_scores] || options[:explain_score]
        with_payloads = options[:with_payloads]
        no_content = options[:no_content]
        decode_fields = options[:decode_fields] || {}

        send_command(["FT.SEARCH"] + args.flatten.compact) do |reply|
          ResultParser.search(
            reply,
            with_scores: !!with_scores,
            with_payloads: !!with_payloads,
            no_content: !!no_content,
            decode_fields: decode_fields
          )
        end
      end

      # Return information and statistics about an index.
      #
      # @example
      #   redis.ft_info("idx")["num_docs"] # => 42
      #
      # @param index_name [String] the index name
      # @return [Hash] index metadata (e.g. +"index_name"+, +"num_docs"+, +"attributes"+)
      def ft_info(index_name)
        send_command(["FT.INFO", index_name]) { |reply| ResultParser.hashify_info(reply) }
      end

      # Drop an index.
      #
      # @param index_name [String] the index name
      # @param delete_documents [Boolean] also delete the indexed documents (+DD+)
      # @return [String] +"OK"+
      def ft_dropindex(index_name, delete_documents: false)
        args = ["FT.DROPINDEX", index_name]
        args << 'DD' if delete_documents
        send_command(args)
      end

      # Run an aggregation pipeline, or read the next batch of a cursor.
      #
      # @example with an AggregateRequest
      #   req = Redis::Commands::Search::AggregateRequest.new("*")
      #           .group_by("@category", Redis::Commands::Search::Reducers.count.as("n"))
      #   redis.ft_aggregate("idx", req) # => #<AggregateResult ...>
      #
      # @param index_name [String] the index name
      # @param query [Search::AggregateRequest, Search::Cursor, String] an aggregate request, a
      #   cursor to read, or a raw query string followed by raw pipeline +args+
      # @param args [Array] raw pipeline tokens when +query+ is a String
      #   (e.g. +"GROUPBY", 1, "@x", "REDUCE", "COUNT", 0, "AS", "n"+)
      # @return [Search::AggregateResult] the result rows (each a Hash) and the cursor id (or nil)
      def ft_aggregate(index_name, query, *args)
        command =
          case query
          when AggregateRequest
            ["FT.AGGREGATE", index_name] + query.to_redis_args
          when Cursor
            ["FT.CURSOR", "READ", index_name] + query.build_args
          else
            # Raw query string: default to DIALECT 2 (matching redis-py) unless one was passed.
            base = ["FT.AGGREGATE", index_name, query, *args]
            base += ["DIALECT", DEFAULT_DIALECT] unless args.flatten.map(&:to_s).include?("DIALECT")
            base
          end

        send_command(command) { |reply| ResultParser.aggregate(reply) }
      end

      # Return the execution plan for a query without running it.
      #
      # @param index_name [String] the index name
      # @param query [String] the query string
      # @return [String] a human-readable description of the query plan
      def ft_explain(index_name, query)
        send_command(["FT.EXPLAIN", index_name, query])
      end

      # Add a field to an existing index's schema (+FT.ALTER ... SCHEMA ADD+).
      #
      # @param index_name [String] the index name
      # @param field_or_args [Search::Field, Array] a {Search::Field} (rendered via +#to_args+) or a
      #   raw token array
      # @return [String] +"OK"+
      # @raise [ArgumentError] if +field_or_args+ is neither a Field nor an Array
      def ft_alter(index_name, field_or_args)
        args = [index_name, "SCHEMA", "ADD"]
        if field_or_args.respond_to?(:to_args)
          args += field_or_args.to_args
        elsif field_or_args.is_a?(Array)
          args += field_or_args
        else
          raise ArgumentError, "field_or_args must be a Field object or an array"
        end
        send_command([:"FT.ALTER", *args])
      end

      # Read the next batch of results from an aggregation cursor.
      #
      # @param index_name [String] the index name
      # @param cursor_id [Integer] the cursor id returned by a previous WITHCURSOR aggregation
      # @return [Search::AggregateResult] the next rows, with +#cursor+ set to the next cursor id
      #   (+0+ when exhausted)
      def ft_cursor_read(index_name, cursor_id)
        send_command(["FT.CURSOR", "READ", index_name, cursor_id]) { |reply| ResultParser.aggregate(reply) }
      end

      # Discard an aggregation cursor.
      #
      # @param index_name [String] the index name
      # @param cursor_id [Integer] the cursor id
      # @return [String] +"OK"+
      def ft_cursor_del(index_name, cursor_id)
        send_command(["FT.CURSOR", "DEL", index_name, cursor_id])
      end

      # Profile the execution of a +SEARCH+ or +AGGREGATE+ query (timing/heuristics).
      #
      # @param index_name [String] the index name
      # @param args [Array] the profile arguments, e.g. +"SEARCH", "QUERY", "<query>"+
      # @return [Array] the raw profile reply (results plus a profiling tree)
      def ft_profile(index_name, *args)
        send_command(["FT.PROFILE", index_name] + args)
      end

      # Run a hybrid (lexical + vector) search.
      #
      # @param index_name [String] the index name
      # @param query [Search::HybridQuery] the combined SEARCH + VSIM query
      # @param combine_method [Search::CombineResultsMethod, nil] the fusion strategy (RRF/LINEAR)
      # @param post_processing [Search::HybridPostProcessingConfig, nil] a post-fusion pipeline
      # @param params_substitution [Hash, nil] query parameter substitutions (+PARAMS+)
      # @param timeout [Integer, nil] query timeout in milliseconds (+TIMEOUT+)
      # @param cursor [Search::HybridCursorQuery, nil] cursor/pagination config (+WITHCURSOR+)
      # @return [Search::HybridResult] the fused result rows, total, warnings and execution time
      #   (or, for a WITHCURSOR query, the per-leg cursor ids)
      def ft_hybrid_search(
        index_name, query:, combine_method: nil, post_processing: nil,
        params_substitution: nil, timeout: nil, cursor: nil, **_options
      )
        args = ["FT.HYBRID", index_name]
        args.concat(query.args)
        args.concat(combine_method.args) if combine_method
        args.concat(post_processing.build_args) if post_processing
        if params_substitution
          args << "PARAMS" << params_substitution.size * 2
          params_substitution.each do |key, value|
            args << key.to_s << value
          end
        end
        args.concat(["TIMEOUT", timeout]) if timeout
        args.concat(cursor.build_args) if cursor
        # NOTE: unlike FT.SEARCH/FT.AGGREGATE, FT.HYBRID does NOT accept a DIALECT token (the
        # server rejects it: "DIALECT is not supported in FT.HYBRID or any of its subqueries").
        # Its legs use the server's search-default-dialect config, so do not append DEFAULT_DIALECT.
        send_command(args) { |reply| ResultParser.hybrid(reply) }
      end

      # Add a suggestion string to an auto-complete dictionary.
      #
      # @param key [String] the suggestion dictionary key
      # @param string [String] the suggestion text
      # @param score [Numeric] the suggestion weight
      # @param options [Hash]
      # @option options [Boolean] :incr increment the existing score instead of replacing it (+INCR+)
      # @option options [String] :payload an opaque payload to store with the suggestion (+PAYLOAD+)
      # @return [Integer] the current size of the suggestion dictionary
      def ft_sugadd(key, string, score, options = {})
        args = ["FT.SUGADD", key, string, score]
        args << 'INCR' if options[:incr]
        args << 'PAYLOAD' << options[:payload] if options[:payload]
        send_command(args)
      end

      # Get auto-complete suggestions for a prefix.
      #
      # @param key [String] the suggestion dictionary key
      # @param prefix [String] the prefix to complete
      # @param options [Hash]
      # @option options [Boolean] :fuzzy perform a fuzzy prefix match (+FUZZY+)
      # @option options [Boolean] :with_scores also return each suggestion's score (+WITHSCORES+)
      # @option options [Boolean] :with_payloads also return each suggestion's payload (+WITHPAYLOADS+)
      # @option options [Integer] :max maximum number of suggestions (+MAX+)
      # @return [Array<String>] the suggestions, interleaved with scores/payloads when requested
      def ft_sugget(key, prefix, options = {})
        args = ["FT.SUGGET", key, prefix]
        args << 'FUZZY' if options[:fuzzy]
        args << 'WITHSCORES' if options[:withscores] || options[:with_scores]
        args << 'WITHPAYLOADS' if options[:withpayloads] || options[:with_payloads]
        args << 'MAX' << options[:max] if options[:max]
        send_command(args)
      end

      # Get the number of entries in a suggestion dictionary.
      #
      # @param key [String] the suggestion dictionary key
      # @return [Integer] the number of suggestions
      def ft_suglen(key)
        send_command(["FT.SUGLEN", key])
      end

      # Delete a string from a suggestion dictionary.
      #
      # @param key [String] the suggestion dictionary key
      # @param string [String] the suggestion text to delete
      # @return [Integer] +1+ if the suggestion existed and was deleted, +0+ otherwise
      def ft_sugdel(key, string)
        send_command(["FT.SUGDEL", key, string])
      end

      # Perform spelling correction over a query against an index.
      #
      # @example
      #   redis.ft_spellcheck("idx", "hello wrld")
      #     # => { "wrld" => [{ "suggestion" => "world", "score" => 0.5 }] }
      #
      # @param index_name [String] the index name
      # @param query [String] the query whose terms are checked
      # @param distance [Integer, nil] maximum Levenshtein distance for suggestions (+DISTANCE+)
      # @param include [String, nil] a custom dictionary to include terms from (+TERMS INCLUDE+)
      # @param exclude [String, nil] a custom dictionary to exclude terms from (+TERMS EXCLUDE+)
      # @return [Hash{String=>Array<Hash>}] each misspelled term mapped to an array of
      #   +{ "suggestion" => String, "score" => Numeric }+
      def ft_spellcheck(index_name, query, distance: nil, include: nil, exclude: nil)
        args = ["FT.SPELLCHECK", index_name, query]
        args += ["DISTANCE", distance] if distance
        args += ["TERMS", "INCLUDE", include] if include
        args += ["TERMS", "EXCLUDE", exclude] if exclude

        send_command(args) { |reply| ResultParser.spellcheck(reply) }
      end

      # Add or update a synonym group on an index.
      #
      # @param index_name [String] the index name
      # @param group_id [String] the synonym group id
      # @param terms [Array<String>] the terms to add to the group
      # @param skip_initial_scan [Boolean] do not re-scan existing documents (+SKIPINITIALSCAN+)
      # @return [String] +"OK"+
      def ft_synupdate(index_name, group_id, *terms, skip_initial_scan: false)
        args = [index_name, group_id]
        args << "SKIPINITIALSCAN" if skip_initial_scan
        args += terms
        send_command(["FT.SYNUPDATE"] + args)
      end

      # Dump the synonym groups of an index.
      #
      # @param index_name [String] the index name
      # @return [Hash{String=>Array<String>}] each term mapped to the synonym group ids it belongs to
      def ft_syndump(index_name)
        send_command(["FT.SYNDUMP", index_name]) { |reply| ResultParser.syndump(reply) }
      end

      # List the distinct values of a TAG field.
      #
      # @param index_name [String] the index name
      # @param field_name [String] the TAG field name
      # @return [Array<String>] the distinct tag values (normalized to lowercase unless the field is
      #   case-sensitive)
      def ft_tagvals(index_name, field_name)
        send_command(["FT.TAGVALS", index_name, field_name])
      end

      # Add an alias for an index.
      #
      # @param alias_name [String] the alias
      # @param index_name [String] the index the alias points to
      # @return [String] +"OK"+
      def ft_aliasadd(alias_name, index_name)
        send_command(["FT.ALIASADD", alias_name, index_name])
      end

      # Repoint an existing alias to a different index (or create it if absent).
      #
      # @param alias_name [String] the alias
      # @param index_name [String] the index the alias should point to
      # @return [String] +"OK"+
      def ft_aliasupdate(alias_name, index_name)
        send_command(["FT.ALIASUPDATE", alias_name, index_name])
      end

      # Remove an index alias.
      #
      # @param alias_name [String] the alias
      # @return [String] +"OK"+
      def ft_aliasdel(alias_name)
        send_command(["FT.ALIASDEL", alias_name])
      end

      # List all aliases associated with an index (Redis 8.10+).
      #
      # @param index_name [String] the index name
      # @return [Array<String>] the aliases pointing to the index (empty when none)
      # @raise [Redis::CommandError] if the index does not exist
      def ft_aliaslist(index_name)
        send_command(["FT.ALIASLIST", index_name])
      end

      # Add terms to a custom dictionary.
      #
      # @param dict_name [String] the dictionary name
      # @param terms [Array<String>] the terms to add
      # @return [Integer] the number of new terms added
      def ft_dictadd(dict_name, *terms)
        send_command(["FT.DICTADD", dict_name] + terms)
      end

      # Remove terms from a custom dictionary.
      #
      # @param dict_name [String] the dictionary name
      # @param terms [Array<String>] the terms to remove
      # @return [Integer] the number of terms removed
      def ft_dictdel(dict_name, *terms)
        send_command(["FT.DICTDEL", dict_name] + terms)
      end

      # Dump all terms in a custom dictionary.
      #
      # @param dict_name [String] the dictionary name
      # @return [Array<String>] the terms in the dictionary
      def ft_dictdump(dict_name)
        send_command(["FT.DICTDUMP", dict_name])
      end

      # Set a runtime Query Engine configuration option.
      #
      # @param option [String] the option name (or +"*"+)
      # @param value [String, Integer] the value
      # @return [String] +"OK"+
      def ft_config_set(option, value)
        send_command(["FT.CONFIG", "SET", option, value])
      end

      # Get a runtime Query Engine configuration option.
      #
      # @param option [String] the option name, or +"*"+ for all options
      # @return [Hash] option name => value
      def ft_config_get(option)
        send_command(["FT.CONFIG", "GET", option]) { |reply| ResultParser.config_get(reply) }
      end
    end
  end
end
