# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # A fluent builder for FT.SEARCH query strings and their options.
      #
      # Chainable setter methods (+filter+, +paging+, +sort_by+, ...) return +self+ so calls can
      # be strung together, and a predicate DSL (+tag+/+text+/+numeric+ combined with +and_+/+or_+)
      # builds the query string itself. {#to_redis_args} renders the whole thing into the argument
      # array passed to +FT.SEARCH+.
      #
      # @example
      #   query = Redis::Commands::Search::Query.new("hello")
      #     .paging(0, 10)
      #     .sort_by("price", asc: false)
      #   query.to_redis_args # => ["hello", "SORTBY", "price", "DESC", "LIMIT", 0, 10, "DIALECT", 2]
      class Query
        # @return [Hash] the accumulated query options (dialect, limit, sortby, scorer, ...)
        # @return [Hash] map of return-field name => whether its value should be JSON-decoded
        # @return [Array<Array>] the +FILTER+ clauses as +[field, min, max]+ triples
        # @return [Array<Array>, nil] the +GEOFILTER+ clauses as +[field, lon, lat, radius, unit]+ tuples
        attr_reader :options, :return_fields_decode, :filters, :geo_filters
        # @return [Array] the fields to RETURN
        # @return [Hash, nil] the HIGHLIGHT options
        # @return [Hash, nil] the SUMMARIZE options
        attr_accessor :return_fields, :highlight_options, :summarize_options

        # @param base [String, nil] an optional base query string used when no predicates are added
        def initialize(base = nil)
          @base = base
          @predicate_collection = [PredicateCollection.new(:and)]
          @filters = []
          @options = { dialect: DEFAULT_DIALECT } # Default dialect, matching redis-py
          @return_fields = []
          @return_fields_decode = {}
          @summarize_options = nil
          @highlight_options = nil
          @language = nil
          @verbatim = false
          @no_stopwords = false
          @with_payloads = false
          @slop = nil
          @in_order = false
          @no_content = false
          @limit_ids = nil
        end

        # Build a Query by evaluating +block+ in the context of a fresh instance.
        #
        # @example
        #   Redis::Commands::Search::Query.build { paging(0, 5); sort_by("name") }
        #
        # @yield evaluated via +instance_eval+ against the new Query
        # @return [Query] the populated query
        def self.build(&block)
          instance = new
          instance.instance_eval(&block)
          instance
        end

        # Add a numeric +FILTER+ clause.
        #
        # @param field [String] the numeric field name
        # @param min [Numeric, String] the lower bound (also used as upper bound when +max+ is nil)
        # @param max [Numeric, String, nil] the upper bound
        # @return [self]
        def filter(field, min, max = nil)
          max ||= min
          @filters << [field, min, max]
          self
        end

        # Add a +GEOFILTER+ clause restricting results to a radius around a point.
        #
        # @param field [String] the geo field name
        # @param lon [Numeric] the longitude of the center
        # @param lat [Numeric] the latitude of the center
        # @param radius [Numeric] the radius
        # @param unit [String] the radius unit ("m", "km", "mi", "ft")
        # @return [self]
        def geo_filter(field, lon, lat, radius, unit = 'km')
          @geo_filters ||= []
          @geo_filters << [field, lon, lat, radius, unit]
          self
        end

        # Restrict the search to the given document ids (+INKEYS+).
        #
        # @param ids [Array<String>] the document ids to limit to
        # @return [self]
        def limit_ids(*ids)
          @limit_ids = ids
          self
        end

        # Set the +LIMIT+ (paging) for the result set.
        #
        # @param offset [Integer] the index of the first result to return
        # @param limit [Integer] the maximum number of results to return
        # @return [self]
        def paging(offset, limit)
          @options[:limit] = [offset, limit]
          self
        end

        # Set the +SORTBY+ field and direction.
        #
        # Supports both styles: a positional +order+ ("ASC"/"DESC" symbol or string) and the
        # +asc:+ keyword. When +order+ is given it takes precedence over +asc:+.
        #
        # @param field [String] the field to sort by
        # @param order [Symbol, String, nil] explicit order, e.g. +:asc+ or "DESC"
        # @param asc [Boolean] sort ascending when true, descending otherwise (used when +order+ is nil)
        # @return [self]
        def sort_by(field, order = nil, asc: true)
          # Support both old style (order as symbol/string) and new style (asc as boolean)
          direction = if order.nil?
            # New style: use asc parameter
            asc ? "ASC" : "DESC"
          else
            # Old style: order is a symbol or string
            order.to_s.upcase
          end
          @options[:sortby] = [field, direction]
          self
        end

        # Set the fields to +RETURN+, replacing any previously configured ones.
        #
        # @param fields [Array<String>] the field names to return
        # @return [self]
        def return(*fields)
          @return_fields = fields
          self
        end

        # Append a single field to +RETURN+, optionally aliased and/or JSON-decoded.
        #
        # @param field [String] the field name to return
        # @param as_field [String, nil] an alias to expose the field under (+AS+)
        # @param decode_field [Boolean] whether the returned value should be JSON-decoded in results
        # @return [self]
        def return_field(field, as_field: nil, decode_field: true)
          @return_fields ||= []
          @return_fields_decode ||= {}

          @return_fields << field
          @return_fields_decode[field] = decode_field

          if as_field
            @return_fields << "AS" << as_field
          end

          self
        end

        # Set the query +LANGUAGE+ used for stemming.
        #
        # @param lang [String] the language name, e.g. "english"
        # @return [self]
        def language(lang)
          @language = lang
          self
        end

        # Disable stemming for the query (+VERBATIM+).
        #
        # @return [self]
        def verbatim
          @verbatim = true
          self
        end

        # Set the query +EXPANDER+ (custom query expander).
        #
        # @param expander_name [String] the expander name
        # @return [self]
        def expander(expander_name)
          @expander = expander_name
          self
        end

        # Do not filter out stopwords (+NOSTOPWORDS+).
        #
        # @return [self]
        def no_stopwords
          @no_stopwords = true
          self
        end

        # Return the relevance score of each document (+WITHSCORES+).
        #
        # @return [self]
        def with_scores
          @options[:withscores] = true
          self
        end

        # Set the scoring function (+SCORER+).
        #
        # @param scorer_name [String] the scorer name, e.g. "BM25"
        # @return [self]
        def scorer(scorer_name)
          @options[:scorer] = scorer_name
          self
        end

        # Return the payload attached to each document (+WITHPAYLOADS+).
        #
        # @return [self]
        def with_payloads
          @with_payloads = true
          self
        end

        # Set the allowed +SLOP+ (number of intervening terms) for phrase matching.
        #
        # @param value [Integer] the slop value
        # @return [self]
        def slop(value)
          @slop = value
          self
        end

        # Require query terms to appear in the same order as in the query (+INORDER+).
        #
        # @return [self]
        def in_order
          @in_order = true
          self
        end

        # Set the query +TIMEOUT+.
        #
        # @param milliseconds [Integer] the timeout in milliseconds
        # @return [self]
        def timeout(milliseconds)
          @timeout = milliseconds
          self
        end

        # Return only document ids, without their contents (+NOCONTENT+).
        #
        # @return [self]
        def no_content
          @no_content = true
          self
        end

        # Restrict the search to the given fields (+INFIELDS+).
        #
        # @param fields [Array<String>] the field names to search within
        # @return [self]
        def limit_fields(*fields)
          @limit_fields = fields
          self
        end

        # Configure result +HIGHLIGHT+ing.
        #
        # @param fields [String, Array<String>, nil] the fields to highlight (all when nil)
        # @param tags [Array<String>] the opening and closing tags wrapped around matches
        # @return [self]
        def highlight(fields: nil, tags: ["<b>", "</b>"])
          @highlight_options = {
            fields: Array(fields),
            tags: tags
          }
          self
        end

        # Configure result +SUMMARIZE+ation (fragment extraction around matches).
        #
        # @param fields [String, Array<String>, nil] the fields to summarize (all when nil)
        # @param separator [String] the string placed between fragments
        # @param len [Integer] the number of words per fragment
        # @param frags [Integer] the number of fragments to extract
        # @return [self]
        def summarize(fields: nil, separator: "...", len: 20, frags: 3)
          @summarize_options = {
            fields: Array(fields),
            separator: separator,
            len: len,
            frags: frags
          }
          self
        end

        # Set the query +DIALECT+ version.
        #
        # @param dialect_version [Integer] the dialect version (defaults to 2)
        # @return [self]
        def dialect(dialect_version)
          @options[:dialect] = dialect_version
          self
        end

        # Return an explanation of the score of each document (+EXPLAINSCORE+).
        #
        # @return [self]
        def explain_score
          @options[:explainscore] = true
          self
        end

        # Internal getters used by Index#search to read accumulated state - unlike the
        # chainable setters above, these return the stored value rather than +self+.
        # :nodoc:
        def limit_ids_value
          @limit_ids
        end

        # :nodoc:
        def language_value
          @language
        end

        # :nodoc:
        def verbatim_value
          @verbatim
        end

        # :nodoc:
        def no_stopwords_value
          @no_stopwords
        end

        # :nodoc:
        def no_content_value
          @no_content
        end

        # :nodoc:
        def with_payloads_value
          @with_payloads
        end

        # :nodoc:
        def slop_value
          @slop
        end

        # :nodoc:
        def in_order_value
          @in_order
        end

        ## -------------
        ## query builder
        ## -------------

        # Open an OR group: predicates added inside +block+ are joined with +|+.
        #
        # @yield builds predicates that are combined with OR
        # @return [self]
        def or_(&block)
          new_collection(:or, &block)
        end

        # Open an AND group: predicates added inside +block+ are joined with a space.
        #
        # @yield builds predicates that are combined with AND
        # @return [self]
        def and_(&block)
          new_collection(:and, &block)
        end

        # Add a built predicate to the current collection.
        #
        # @param predicate [Predicate] the predicate to add
        # @return [self]
        def add_predicate(predicate)
          @predicate_collection.last.add(predicate)
          self
        end

        # Push a new predicate collection of +type+, evaluate the block against it, then fold it
        # back into the parent collection.
        #
        # @param type [Symbol] +:and+ or +:or+
        # @yield builds predicates inside the new collection
        # @return [self]
        def new_collection(type)
          collection = PredicateCollection.new(type)
          @predicate_collection << collection
          yield if block_given?
          @predicate_collection.pop
          @predicate_collection.last.add(collection)
          self
        end

        # Begin a tag-field predicate bound to this query (call +.eq+ on the result).
        #
        # @param field [String] the tag field name
        # @return [TagField] a field bound to this query
        def tag(field)
          TagField.new(field, self)
        end

        # Begin a text-field predicate bound to this query (call +.match+ on the result).
        #
        # @param field [String] the text field name
        # @return [TextField] a field bound to this query
        def text(field)
          TextField.new(field, self)
        end

        # Begin a numeric-field predicate bound to this query (call +.gt+/+.lt+/+.between+ on it).
        #
        # @param field [String] the numeric field name
        # @return [NumericField] a field bound to this query
        def numeric(field)
          NumericField.new(field, self)
        end

        # Render the query and all configured options into the +FT.SEARCH+ argument array.
        #
        # @return [Array] the argument array whose first element is the query string and whose
        #   remaining elements are option tokens
        def to_redis_args
          args = [query_string]
          append_boolean_options(args)
          append_scorer(args)
          append_with_scores(args)
          append_limit_fields(args)
          append_limit_ids(args)
          append_filters(args)
          append_geo_filters(args)
          append_return_fields(args)
          append_summarize_options(args)
          append_highlight_options(args)
          append_slop(args)
          append_timeout(args)
          append_language(args)
          append_expander(args)
          append_in_order(args)
          append_sort_by(args)
          append_limit(args)
          append_dialect(args)
          args.flatten
        end

        # Evaluate +block+ against this query (used to populate it via the DSL).
        #
        # @yield evaluated via +instance_eval+ against this query
        # @return [Object, nil] the block's return value, or nil when no block is given
        def evaluate(&block)
          if block_given?
            instance_eval(&block)
          end
        end

        private

        def query_string
          if @predicate_collection.first.predicates.empty?
            @base || "*"
          else
            @predicate_collection.first.to_s
          end
        end

        def append_boolean_options(args)
          args << "NOCONTENT" if @no_content
          args << "VERBATIM" if @verbatim
          args << "NOSTOPWORDS" if @no_stopwords
          args << "WITHPAYLOADS" if @with_payloads
        end

        def append_scorer(args)
          args.concat(["SCORER", @options[:scorer]]) if @options[:scorer]
        end

        def append_with_scores(args)
          args << "WITHSCORES" if @options[:withscores]
        end

        def append_limit_fields(args)
          if @limit_fields && !@limit_fields.empty?
            args.concat(["INFIELDS", @limit_fields.size, *@limit_fields.map(&:to_s)])
          end
        end

        def append_limit_ids(args)
          if @limit_ids && !@limit_ids.empty?
            args.concat(["INKEYS", @limit_ids.size, *@limit_ids])
          end
        end

        def append_filters(args)
          @filters.each do |field, min, max|
            args.concat(["FILTER", field, min, max])
          end
        end

        def append_geo_filters(args)
          @geo_filters&.each do |field, lon, lat, radius, unit|
            args.concat(["GEOFILTER", field, lon, lat, radius, unit])
          end
        end

        def append_return_fields(args)
          if @return_fields && !@return_fields.empty?
            args.concat(["RETURN", @return_fields.size, *@return_fields])
          end
        end

        def append_summarize_options(args)
          if @summarize_options
            args << "SUMMARIZE"
            if @summarize_options[:fields].any?
              args.concat(["FIELDS", @summarize_options[:fields].size, *@summarize_options[:fields].map(&:to_s)])
            end
            args.concat(["FRAGS", @summarize_options[:frags]])
            args.concat(["LEN", @summarize_options[:len]])
            args.concat(["SEPARATOR", @summarize_options[:separator]])
          end
        end

        def append_highlight_options(args)
          if @highlight_options
            args << "HIGHLIGHT"
            if @highlight_options[:fields].any?
              args.concat(["FIELDS", @highlight_options[:fields].size, *@highlight_options[:fields].map(&:to_s)])
            end
            args.concat(["TAGS", *@highlight_options[:tags]])
          end
        end

        def append_slop(args)
          args.concat(["SLOP", @slop]) if @slop
        end

        def append_timeout(args)
          args.concat(["TIMEOUT", @timeout]) if @timeout
        end

        def append_language(args)
          args.concat(["LANGUAGE", @language]) if @language
        end

        def append_expander(args)
          args.concat(["EXPANDER", @expander]) if @expander
        end

        def append_in_order(args)
          args << "INORDER" if @in_order
        end

        def append_sort_by(args)
          if @options[:sortby]
            args.concat(["SORTBY", @options[:sortby][0], @options[:sortby][1]])
          end
        end

        def append_limit(args)
          if @options[:limit]
            args.concat(["LIMIT", @options[:limit][0], @options[:limit][1]])
          end
        end

        def append_dialect(args)
          args.concat(["DIALECT", @options[:dialect]]) if @options[:dialect]
        end
      end

      # Abstract base for a single query-string predicate. Subclasses render themselves into a
      # query-string fragment via +#to_s+.
      class Predicate
        # @return [String] the field the predicate applies to
        attr_reader :field

        # @param field [String] the field name
        def initialize(field)
          @field = field
        end

        # @raise [NotImplementedError] always; subclasses must override
        # @return [String] the query-string fragment
        def to_s
          raise NotImplementedError
        end
      end

      # A tag-equality predicate rendering +(@field:{value})+.
      class TagEqualityPredicate < Predicate
        # @param field [String] the tag field name
        # @param value [String] the tag value to match
        def initialize(field, value)
          super(field)
          @value = value
        end

        # @return [String] the query-string fragment, e.g. +(@color:{red})+
        def to_s
          "(@#{@field}:{#{@value}})"
        end
      end

      # A text-match predicate rendering +(@field:pattern)+.
      class TextMatchPredicate < Predicate
        # @param field [String] the text field name
        # @param pattern [String] the text pattern to match
        def initialize(field, pattern)
          super(field)
          @pattern = pattern
        end

        # @return [String] the query-string fragment, e.g. +(@title:hello)+
        def to_s
          "(@#{@field}:#{@pattern})"
        end
      end

      # A numeric-range predicate rendering +(@field:[min max])+.
      class RangePredicate < Predicate
        # @param field [String] the numeric field name
        # @param min [Numeric, String] the lower bound
        # @param max [Numeric, String] the upper bound
        def initialize(field, min, max)
          super(field)
          @min = min
          @max = max
        end

        # @return [String] the query-string fragment, e.g. +(@price:[10 20])+
        def to_s
          "(@#{@field}:[#{@min} #{@max}])"
        end
      end

      # An ordered collection of predicates joined with AND (a space) or OR (+ | +).
      class PredicateCollection
        # @return [Symbol] +:and+ or +:or+
        # @return [Array<Predicate, PredicateCollection>] the contained predicates
        attr_reader :type, :predicates

        # @param type [Symbol] +:and+ to join with a space, +:or+ to join with +|+
        def initialize(type)
          @type = type
          @predicates = []
        end

        # Add a predicate (or nested collection) to this collection.
        #
        # @param predicate [Predicate, PredicateCollection] the predicate to add
        # @return [Array] the updated list of predicates
        def add(predicate)
          @predicates << predicate
        end

        # @return [String] the parenthesised, joined query-string fragment
        def to_s
          joiner = @type == :or ? ' | ' : ' '
          "(#{@predicates.join(joiner)})"
        end
      end
    end
  end
end
