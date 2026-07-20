# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # The textual +SEARCH+ leg of an FT.HYBRID query.
      #
      # Chainable setters (+scorer+, +yield_score_as+) return +self+; {#args} renders the leg
      # into its argument tokens, beginning with "SEARCH".
      class HybridSearchQuery
        # @return [String] the search query string
        attr_reader :query_string

        # @param query_string [String] the search query string
        # @param scorer [String, nil] the scoring function
        # @param yield_score_as [String, nil] the alias to expose the search score under
        def initialize(query_string, scorer: nil, yield_score_as: nil)
          @query_string = query_string
          @scorer = scorer
          @yield_score_as = yield_score_as
        end

        # Set the scoring function (+SCORER+).
        #
        # @param scorer [String] the scorer name
        # @return [self]
        def scorer(scorer)
          @scorer = scorer
          self
        end

        # Expose the search score under an alias (+YIELD_SCORE_AS+).
        #
        # @param alias_name [String] the alias for the score
        # @return [self]
        def yield_score_as(alias_name)
          @yield_score_as = alias_name
          self
        end

        # @return [Array] the +SEARCH+ leg argument tokens, beginning with "SEARCH"
        def args
          result = ["SEARCH", @query_string]
          result << "SCORER" << @scorer if @scorer
          result << "YIELD_SCORE_AS" << @yield_score_as if @yield_score_as
          result
        end
      end

      # The vector-similarity +VSIM+ leg of an FT.HYBRID query.
      #
      # Chainable setters (+vsim_method_params+, +filter+, +yield_score_as+) return +self+;
      # {#args} renders the leg into its argument tokens, beginning with "VSIM".
      class HybridVsimQuery
        # @return [String] the vector field name
        # @return [String] the query vector data (blob)
        attr_reader :vector_field, :vector_data

        # @param vector_field_name [String] the vector field to search
        # @param vector_data [String] the query vector blob
        # @param vsim_search_method [Symbol, String, nil] the search method, e.g. +:knn+ or +:range+
        # @param vsim_search_method_params [Hash, nil] the search-method parameters
        # @param filter [HybridFilter, nil] an optional filter applied to the vector leg
        # @param yield_score_as [String, nil] the alias to expose the vector score under
        def initialize(
          vector_field_name:, vector_data:,
          vsim_search_method: nil, vsim_search_method_params: nil,
          filter: nil, yield_score_as: nil
        )
          @vector_field = vector_field_name
          @vector_data = vector_data
          @vsim_method_params = nil
          @filter = filter
          @yield_score_as = yield_score_as

          if vsim_search_method && vsim_search_method_params
            vsim_method_params(vsim_search_method, **vsim_search_method_params)
          end
        end

        # Set the vector search method and its parameters (e.g. +KNN+ / +RANGE+).
        #
        # @param method [Symbol, String] the search method (upcased into a token)
        # @param kwargs [Hash] the method parameters, emitted as upcased key/value pairs
        # @return [self]
        def vsim_method_params(method, **kwargs)
          @vsim_method_params = [method.to_s.upcase]
          if kwargs.any?
            @vsim_method_params << kwargs.size * 2
            kwargs.each do |key, value|
              @vsim_method_params << key.to_s.upcase << value
            end
          end
          self
        end

        # Set a filter applied to the vector leg (+FILTER+).
        #
        # @param flt [HybridFilter] the filter to apply
        # @return [self]
        def filter(flt)
          @filter = flt
          self
        end

        # Expose the vector score under an alias (+YIELD_SCORE_AS+).
        #
        # @param alias_name [String] the alias for the score
        # @return [self]
        def yield_score_as(alias_name)
          @yield_score_as = alias_name
          self
        end

        # @return [Array] the +VSIM+ leg argument tokens, beginning with "VSIM"
        def args
          result = ["VSIM", @vector_field, @vector_data]
          result.concat(@vsim_method_params) if @vsim_method_params
          result.concat(@filter.args) if @filter
          result << "YIELD_SCORE_AS" << @yield_score_as if @yield_score_as
          result
        end
      end

      # An FT.HYBRID query combining a textual {HybridSearchQuery} leg and a
      # {HybridVsimQuery} vector leg.
      class HybridQuery
        # @param search_query [HybridSearchQuery] the textual search leg
        # @param vector_similarity_query [HybridVsimQuery] the vector-similarity leg
        def initialize(search_query, vector_similarity_query)
          @search_query = search_query
          @vector_similarity_query = vector_similarity_query
        end

        # @return [Array] the concatenated argument tokens of both legs (SEARCH then VSIM)
        def args
          result = []
          result.concat(@search_query.args)
          result.concat(@vector_similarity_query.args)
          result
        end
      end

      # Constants for the result-combination methods used by {CombineResultsMethod}.
      module CombinationMethods
        # Reciprocal Rank Fusion.
        RRF = "RRF"
        # Linear combination of leg scores.
        LINEAR = "LINEAR"
      end

      # Constants for the vector search methods used by {HybridVsimQuery}.
      module VectorSearchMethods
        # K-nearest-neighbours search.
        KNN = "KNN"
        # Range search.
        RANGE = "RANGE"
      end

      # The +COMBINE+ clause of an FT.HYBRID query, describing how the two legs' results are fused.
      class CombineResultsMethod
        # @param method [String] the combination method (see {CombinationMethods})
        # @param kwargs [Hash] the method parameters, emitted as upcased key/value pairs
        def initialize(method, **kwargs)
          @method = method
          @kwargs = kwargs
        end

        # @return [Array<String>] the +COMBINE+ argument tokens, beginning with "COMBINE"
        def args
          result = ["COMBINE", @method, (@kwargs.size * 2).to_s]
          @kwargs.each do |key, value|
            result << key.to_s.upcase << value.to_s
          end
          result
        end

        # Build a Reciprocal Rank Fusion (+RRF+) combine method.
        #
        # @param window [Integer, nil] the +WINDOW+ size
        # @param constant [Numeric, nil] the +CONSTANT+ value
        # @return [CombineResultsMethod]
        def self.rrf(window: nil, constant: nil)
          # Guard on nil (not truthiness): 0 is a legitimate value and, unlike some languages,
          # truthy in Ruby — but nil-checking keeps "was it provided?" explicit and correct.
          kwargs = {}
          kwargs[:window] = window unless window.nil?
          kwargs[:constant] = constant unless constant.nil?
          new(CombinationMethods::RRF, **kwargs)
        end

        # Build a +LINEAR+ combine method.
        #
        # @param alpha [Numeric, nil] the weight of the first leg
        # @param beta [Numeric, nil] the weight of the second leg
        # @return [CombineResultsMethod]
        def self.linear(alpha: nil, beta: nil)
          # Guard on nil (not truthiness) so alpha/beta of 0 are still emitted.
          kwargs = {}
          kwargs[:alpha] = alpha unless alpha.nil?
          kwargs[:beta] = beta unless beta.nil?
          new(CombinationMethods::LINEAR, **kwargs)
        end
      end

      # A +FILTER+ clause used within a hybrid query leg.
      class HybridFilter
        # @return [Array] the +FILTER+ argument tokens, +["FILTER", conditions]+
        attr_reader :args

        # @param conditions [String] the filter expression
        def initialize(conditions)
          @args = ["FILTER", conditions]
        end
      end

      # Builder for the post-processing pipeline applied to FT.HYBRID results.
      #
      # Chainable setters (+load+, +group_by+, +apply+, +sort_by+, +filter+, +limit+) return
      # +self+; {#build_args} renders the configured steps into argument tokens.
      class HybridPostProcessingConfig
        def initialize
          @load_statements = []
          @apply_statements = []
          @groupby_statements = []
          @sortby_fields = []
          @filter = nil
          @limit = nil
        end

        # Add a +LOAD+ step loading the given fields.
        #
        # @param fields [Array<String>] the fields to load (space-separated strings are split)
        # @return [self]
        def load(*fields)
          unless fields.empty?
            fields_str = fields.join(" ")
            fields_list = fields_str.split(" ")
            @load_statements.concat(["LOAD", fields_list.size, *fields_list])
          end
          self
        end

        # Add a +GROUPBY+ step with optional +REDUCE+ functions.
        #
        # @param fields [String, Array<String>] the field(s) to group by
        # @param reducers [Array<Reducers>] the reducers applied to each group
        # @return [self]
        def group_by(fields, *reducers)
          ret = ["GROUPBY", Array(fields).size.to_s, *Array(fields)]
          reducers.each do |reducer|
            ret.concat(["REDUCE", reducer.name, reducer.args.size.to_s])
            ret.concat(reducer.args)
            ret.concat(["AS", reducer.alias_name]) if reducer.alias_name
          end
          @groupby_statements.concat(ret)
          self
        end

        # Add one +APPLY+ step per expression.
        #
        # @param kwexpr [Hash{Symbol => String}] map of result alias => expression
        # @return [self]
        def apply(**kwexpr)
          apply_args = []
          kwexpr.each do |alias_name, expr|
            ret = ["APPLY", expr]
            ret.concat(["AS", alias_name.to_s]) if alias_name
            apply_args.concat(ret)
          end
          @apply_statements.concat(apply_args)
          self
        end

        # Add a +SORTBY+ step.
        #
        # @param sortby_fields [Array<SortbyField>] the fields to sort by
        # @return [self]
        def sort_by(*sortby_fields)
          @sortby_fields = sortby_fields
          self
        end

        # Add a +FILTER+ step.
        #
        # @param flt [HybridFilter] the filter to apply
        # @return [self]
        def filter(flt)
          @filter = flt
          self
        end

        # Add a +LIMIT+ (paging) step.
        #
        # @param offset [Integer] the index of the first row to return
        # @param num [Integer] the maximum number of rows to return
        # @return [self]
        def limit(offset, num)
          @limit = { offset: offset, num: num }
          self
        end

        # Render the post-processing pipeline into its argument tokens.
        #
        # Steps are emitted in order: LOAD, GROUPBY, APPLY, SORTBY, FILTER, LIMIT.
        #
        # @return [Array] the argument token array
        def build_args
          args = []
          args.concat(@load_statements) if @load_statements.any?
          args.concat(@groupby_statements) if @groupby_statements.any?
          args.concat(@apply_statements) if @apply_statements.any?
          if @sortby_fields.any?
            sortby_args = []
            @sortby_fields.each do |f|
              sortby_args.concat(f.args)
            end
            args.concat(["SORTBY", sortby_args.size, *sortby_args])
          end
          args.concat(@filter.args) if @filter
          args.concat(["LIMIT", @limit[:offset], @limit[:num]]) if @limit
          args
        end
      end

      # The +WITHCURSOR+ clause for paging through FT.HYBRID results.
      class HybridCursorQuery
        # @param count [Integer] the cursor +COUNT+ (batch size, 0 to omit)
        # @param max_idle [Integer] the cursor +MAXIDLE+ in milliseconds (0 to omit)
        def initialize(count: 0, max_idle: 0)
          @count = count
          @max_idle = max_idle
        end

        # Render the cursor arguments.
        #
        # @return [Array<String>] the argument tokens, beginning with "WITHCURSOR"
        def build_args
          args = ["WITHCURSOR"]
          args.concat(["COUNT", @count.to_s]) if @count > 0
          args.concat(["MAXIDLE", @max_idle.to_s]) if @max_idle > 0
          args
        end
      end

      # A single field/direction pair for hybrid-search +SORTBY+.
      class SortbyField
        # @return [Array<String>] the argument tokens, +[field, "ASC"|"DESC"]+
        attr_reader :args

        # @param field [String] the field to sort by
        # @param asc [Boolean] sort ascending when true, descending otherwise
        def initialize(field, asc: true)
          @args = [field, asc ? "ASC" : "DESC"]
        end
      end
    end
  end
end
