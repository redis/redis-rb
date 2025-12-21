# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class Query
        attr_reader :options, :return_fields_decode

        def initialize(base = nil)
          @base = base
          @predicate_collection = [PredicateCollection.new(:and)]
          @filters = []
          @options = { dialect: 2 } # Default dialect is 2
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

        def self.build(&block)
          instance = new
          instance.instance_eval(&block)
          instance
        end

        def filter(field, min, max = nil)
          max ||= min
          @filters << [field, min, max]
          self
        end

        def geo_filter(field, lon, lat, radius, unit = 'km')
          @geo_filters ||= []
          @geo_filters << [field, lon, lat, radius, unit]
          self
        end

        def limit_ids(*ids)
          @limit_ids = ids
          self
        end

        def paging(offset, limit)
          @options[:limit] = [offset, limit]
          self
        end

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

        def return(*fields)
          @return_fields = fields
          self
        end

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

        def language(lang)
          @language = lang
          self
        end

        def verbatim
          @verbatim = true
          self
        end

        def expander(expander_name)
          @expander = expander_name
          self
        end

        def no_stopwords
          @no_stopwords = true
          self
        end

        def with_scores
          @options[:withscores] = true
          self
        end

        def scorer(scorer_name)
          @options[:scorer] = scorer_name
          self
        end

        def with_payloads
          @with_payloads = true
          self
        end

        def slop(value)
          @slop = value
          self
        end

        def in_order
          @in_order = true
          self
        end

        def timeout(milliseconds)
          @timeout = milliseconds
          self
        end

        def no_content
          @no_content = true
          self
        end

        def limit_fields(*fields)
          @limit_fields = fields
          self
        end

        def highlight(fields: nil, tags: ["<b>", "</b>"])
          @highlight_options = {
            fields: Array(fields),
            tags: tags
          }
          self
        end

        def summarize(fields: nil, separator: "...", len: 20, frags: 3)
          @summarize_options = {
            fields: Array(fields),
            separator: separator,
            len: len,
            frags: frags
          }
          self
        end

        def dialect(dialect_version)
          @options[:dialect] = dialect_version
          self
        end

        ## -------------
        ## query builder
        ## -------------

        def or_(&block)
          new_collection(:or, &block)
        end

        def and_(&block)
          new_collection(:and, &block)
        end

        def add_predicate(predicate)
          @predicate_collection.last.add(predicate)
          self
        end

        def new_collection(type)
          collection = PredicateCollection.new(type)
          @predicate_collection << collection
          yield if block_given?
          @predicate_collection.pop
          @predicate_collection.last.add(collection)
          self
        end

        def tag(field)
          TagField.new(field, self)
        end

        def text(field)
          TextField.new(field, self)
        end

        def numeric(field)
          NumericField.new(field, self)
        end

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

      class Predicate
        attr_reader :field

        def initialize(field)
          @field = field
        end

        def to_s
          raise NotImplementedError
        end
      end

      class TagEqualityPredicate < Predicate
        def initialize(field, value)
          super(field)
          @value = value
        end

        def to_s
          "(@#{@field}:{#{@value}})"
        end
      end

      class TextMatchPredicate < Predicate
        def initialize(field, pattern)
          super(field)
          @pattern = pattern
        end

        def to_s
          "(@#{@field}:#{@pattern})"
        end
      end

      class RangePredicate < Predicate
        def initialize(field, min, max)
          super(field)
          @min = min
          @max = max
        end

        def to_s
          "(@#{@field}:[#{@min} #{@max}])"
        end
      end

      class PredicateCollection
        attr_reader :type, :predicates

        def initialize(type)
          @type = type
          @predicates = []
        end

        def add(predicate)
          @predicates << predicate
        end

        def to_s
          joiner = @type == :or ? ' | ' : ' '
          "(#{@predicates.join(joiner)})"
        end
      end
    end
  end
end
