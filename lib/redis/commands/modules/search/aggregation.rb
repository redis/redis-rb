# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # A fluent builder for FT.AGGREGATE requests.
      #
      # Aggregation steps (+group_by+, +sort_by+, +apply+, +filter+, +limit+, +load+) are
      # chained on; each returns +self+. {#to_redis_args} renders them into the argument array
      # passed to +FT.AGGREGATE+, emitting +LOAD+ steps before +DIALECT+ and the remaining steps
      # after it.
      #
      # @example
      #   req = Redis::Commands::Search::AggregateRequest.new("*")
      #     .group_by("@category", Redis::Commands::Search::Reducers.count(alias_name: "n"))
      class AggregateRequest
        # @param query [String] the aggregation query string (defaults to "*")
        # @param with_cursor [Boolean] emit +WITHCURSOR+ to page results with a cursor
        # @param cursor_count [Integer, nil] the cursor +COUNT+ (batch size)
        # @param cursor_max_idle [Integer, nil] the cursor +MAXIDLE+ in milliseconds
        # @param dialect [Integer] the query +DIALECT+ version (defaults to {DEFAULT_DIALECT})
        def initialize(query = "*", with_cursor: false, cursor_count: nil, cursor_max_idle: nil,
                       dialect: DEFAULT_DIALECT)
          @query = query
          @with_cursor = with_cursor
          @cursor_count = cursor_count
          @cursor_max_idle = cursor_max_idle
          @dialect = dialect
          @steps = []
        end

        # Add a +GROUPBY+ step with optional +REDUCE+ functions.
        #
        # @param fields [String, Array<String>] the field(s) to group by
        # @param reducers [Array<Reducers>] the reducers applied to each group
        # @return [self]
        def group_by(fields, *reducers)
          step = ["GROUPBY", Array(fields).size.to_s, *Array(fields)]
          reducers.each do |reducer|
            step.concat(["REDUCE", reducer.name, reducer.args.size.to_s])
            step.concat(reducer.args)
            step.concat(["AS", reducer.alias_name]) if reducer.alias_name
          end
          @steps << step.flatten
          self
        end

        # Add a +SORTBY+ step.
        #
        # @param sort_by_fields [Array<Asc, Desc, String>] the fields to sort by; +Asc+/+Desc+
        #   wrappers carry an explicit direction, plain strings sort with the server default
        # @param max [Integer, nil] limit the sort to the top +MAX+ results
        # @return [self]
        def sort_by(*sort_by_fields, max: nil)
          # Count total arguments (field + order for each)
          nargs = sort_by_fields.sum do |field|
            field.is_a?(Asc) || field.is_a?(Desc) ? 2 : 1
          end

          step = ["SORTBY", nargs]
          sort_by_fields.each do |field|
            if field.is_a?(Asc) || field.is_a?(Desc)
              step << field.name << field.order
            else
              step << field
            end
          end
          step << "MAX" << max if max
          @steps << step
          self
        end

        # Add one +APPLY+ step per expression.
        #
        # @param expressions [Hash{String, Symbol => String}] map of result alias => expression
        # @return [self]
        def apply(expressions)
          expressions.each do |as, expression|
            @steps << ["APPLY", expression, "AS", as.to_s]
          end
          self
        end

        # Add a +LIMIT+ (paging) step.
        #
        # @param offset [Integer] the index of the first row to return
        # @param num [Integer] the maximum number of rows to return
        # @return [self]
        def limit(offset, num)
          @steps << ["LIMIT", offset, num]
          self
        end

        # Add a +FILTER+ step that keeps rows matching +expression+.
        #
        # @param expression [String] the filter expression
        # @return [self]
        def filter(expression)
          @steps << ["FILTER", expression]
          self
        end

        # Add a +LOAD+ step. With no fields, loads all attributes (+LOAD *+).
        #
        # @param fields [Array<String>] the fields to load (empty loads all)
        # @return [self]
        def load(*fields)
          @steps << if fields.empty?
            ["LOAD", "*"]
          else
            ["LOAD", fields.size, *fields.flatten]
          end
          self
        end

        # Include the document scores in the aggregation (+ADDSCORES+).
        #
        # @param add_scores [Boolean] whether to emit +ADDSCORES+
        # @return [self]
        def add_scores(add_scores: true)
          @add_scores = add_scores
          self
        end

        # Set the query +DIALECT+ version.
        #
        # @param dialect_version [Integer] the dialect version
        # @return [self]
        def dialect(dialect_version)
          @dialect = dialect_version
          self
        end

        # Render the request into the +FT.AGGREGATE+ argument array.
        #
        # +LOAD+ steps are emitted before +DIALECT+ and all other steps after it.
        #
        # @return [Array] the argument token array (query string first)
        def to_redis_args
          args = [@query]
          if @with_cursor
            args << "WITHCURSOR"
            args << "COUNT" << @cursor_count if @cursor_count
            args << "MAXIDLE" << @cursor_max_idle if @cursor_max_idle
          end
          args << "ADDSCORES" if @add_scores
          # Add LOAD steps first (before DIALECT)
          load_steps = @steps.select { |step| step[0] == "LOAD" }
          load_steps.each { |step| args.concat(step) }

          args << "DIALECT" << @dialect if @dialect

          # Add remaining steps (after DIALECT)
          other_steps = @steps.reject { |step| step[0] == "LOAD" }
          other_steps.each { |step| args.concat(step) }
          args
        end
      end

      # Wraps a field name with an ascending (+ASC+) sort order for {AggregateRequest#sort_by}.
      class Asc
        # @return [String] the field name
        # @return [String] the order keyword, always "ASC"
        attr_reader :name, :order

        # @param name [String] the field name to sort ascending
        def initialize(name)
          @name = name
          @order = 'ASC'
        end
      end

      # Wraps a field name with a descending (+DESC+) sort order for {AggregateRequest#sort_by}.
      class Desc
        # @return [String] the field name
        # @return [String] the order keyword, always "DESC"
        attr_reader :name, :order

        # @param name [String] the field name to sort descending
        def initialize(name)
          @name = name
          @order = 'DESC'
        end
      end

      # Factory for the +REDUCE+ functions used inside {AggregateRequest#group_by}.
      #
      # Each class method returns a +Reducers+ instance carrying the function name, its
      # arguments, and an optional result alias.
      #
      # @example
      #   Redis::Commands::Search::Reducers.sum("@price", alias_name: "total")
      class Reducers
        # Build a +COUNT+ reducer.
        #
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.count(alias_name: nil)
          new("COUNT", alias_name: alias_name)
        end

        # Build a +COUNT_DISTINCT+ reducer.
        #
        # @param property [String] the property to count distinct values of
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.count_distinct(property, alias_name: nil)
          new("COUNT_DISTINCT", property, alias_name: alias_name)
        end

        # Build a +COUNT_DISTINCTISH+ (approximate distinct count) reducer.
        #
        # @param property [String] the property to count distinct values of
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.count_distinctish(property, alias_name: nil)
          new("COUNT_DISTINCTISH", property, alias_name: alias_name)
        end

        # Build a +SUM+ reducer.
        #
        # @param property [String] the property to sum
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.sum(property, alias_name: nil)
          new("SUM", property, alias_name: alias_name)
        end

        # Build a +MIN+ reducer.
        #
        # @param property [String] the property to take the minimum of
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.min(property, alias_name: nil)
          new("MIN", property, alias_name: alias_name)
        end

        # Build a +MAX+ reducer.
        #
        # @param property [String] the property to take the maximum of
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.max(property, alias_name: nil)
          new("MAX", property, alias_name: alias_name)
        end

        # Build an +AVG+ reducer.
        #
        # @param property [String] the property to average
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.avg(property, alias_name: nil)
          new("AVG", property, alias_name: alias_name)
        end

        # Build a +STDDEV+ (standard deviation) reducer.
        #
        # @param property [String] the property to compute the standard deviation of
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.stddev(property, alias_name: nil)
          new("STDDEV", property, alias_name: alias_name)
        end

        # Build a +QUANTILE+ reducer.
        #
        # @param property [String] the property to compute the quantile of
        # @param quantile [Float] the quantile in the range 0..1
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.quantile(property, quantile, alias_name: nil)
          new("QUANTILE", property, quantile, alias_name: alias_name)
        end

        # Build a +TOLIST+ reducer (collects distinct values into a list).
        #
        # @param property [String] the property to collect
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.tolist(property, alias_name: nil)
          new("TOLIST", property, alias_name: alias_name)
        end

        # Build a +FIRST_VALUE+ reducer, optionally ordered by another property.
        #
        # @param property [String] the property whose first value is taken
        # @param alias_name [String, nil] the result alias
        # @param sort_by [String, nil] the property to order by before taking the first value
        # @param sort_order [Symbol, String, nil] the sort direction ("ASC"/"DESC", default "ASC")
        # @return [Reducers]
        def self.first_value(property, alias_name: nil, sort_by: nil, sort_order: nil)
          args = [property]
          if sort_by
            args << "BY" << sort_by
            args << (sort_order || "ASC").to_s.upcase
          end
          new("FIRST_VALUE", *args, alias_name: alias_name)
        end

        # Build a +RANDOM_SAMPLE+ reducer.
        #
        # @param property [String] the property to sample
        # @param sample_size [Integer] the number of values to sample
        # @param alias_name [String, nil] the result alias
        # @return [Reducers]
        def self.random_sample(property, sample_size, alias_name: nil)
          new("RANDOM_SAMPLE", property, sample_size, alias_name: alias_name)
        end

        # @return [String] the reducer function name
        # @return [Array] the reducer arguments
        # @return [String, nil] the result alias
        attr_reader :name, :args, :alias_name

        # @param name [String] the reducer function name
        # @param args [Array] the reducer arguments
        # @param alias_name [String, nil] the result alias
        def initialize(name, *args, alias_name: nil)
          @name = name
          @args = args
          @alias_name = alias_name
        end

        # Set the result alias (+AS+) for this reducer.
        #
        # @param alias_name [String] the result alias
        # @return [self]
        def as(alias_name)
          @alias_name = alias_name
          self
        end
      end

      # Represents an +FT.CURSOR+ read for paging through aggregation results.
      class Cursor
        # @return [Integer] the cursor id
        # @return [Integer] the +COUNT+ (batch size, 0 to omit)
        attr_accessor :cid, :count

        # @param cid [Integer] the cursor id returned by a prior aggregation
        def initialize(cid)
          @cid = cid
          @count = 0
        end

        # Render the cursor arguments for +FT.CURSOR READ+.
        #
        # @return [Array<String>] the argument token array
        def build_args
          args = [@cid.to_s]
          args.concat(["COUNT", @count.to_s]) if @count > 0
          args
        end
      end
    end
  end
end
