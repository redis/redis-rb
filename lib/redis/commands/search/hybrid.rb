# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class HybridSearchQuery
        attr_reader :query_string

        def initialize(query_string, scorer: nil, yield_score_as: nil)
          @query_string = query_string
          @scorer = scorer
          @yield_score_as = yield_score_as
        end

        def scorer(scorer)
          @scorer = scorer
          self
        end

        def yield_score_as(alias_name)
          @yield_score_as = alias_name
          self
        end

        def args
          result = ["SEARCH", @query_string]
          result << "SCORER" << @scorer if @scorer
          result << "YIELD_SCORE_AS" << @yield_score_as if @yield_score_as
          result
        end
      end

      class HybridVsimQuery
        attr_reader :vector_field, :vector_data

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

        def filter(flt)
          @filter = flt
          self
        end

        def yield_score_as(alias_name)
          @yield_score_as = alias_name
          self
        end

        def args
          result = ["VSIM", @vector_field, @vector_data]
          result.concat(@vsim_method_params) if @vsim_method_params
          result.concat(@filter.args) if @filter
          result << "YIELD_SCORE_AS" << @yield_score_as if @yield_score_as
          result
        end
      end

      class HybridQuery
        def initialize(search_query, vector_similarity_query)
          @search_query = search_query
          @vector_similarity_query = vector_similarity_query
        end

        def args
          result = []
          result.concat(@search_query.args)
          result.concat(@vector_similarity_query.args)
          result
        end
      end

      # Combination methods for hybrid search
      module CombinationMethods
        RRF = "RRF"
        LINEAR = "LINEAR"
      end

      # Vector search methods for hybrid search
      module VectorSearchMethods
        KNN = "KNN"
        RANGE = "RANGE"
      end

      class CombineResultsMethod
        def initialize(method, **kwargs)
          @method = method
          @kwargs = kwargs
        end

        def args
          result = ["COMBINE", @method, (@kwargs.size * 2).to_s]
          @kwargs.each do |key, value|
            result << key.to_s.upcase << value.to_s
          end
          result
        end

        # Class methods for creating combine methods
        def self.rrf(window: nil, constant: nil)
          kwargs = {}
          kwargs[:window] = window if window
          kwargs[:constant] = constant if constant
          new(CombinationMethods::RRF, **kwargs)
        end

        def self.linear(alpha: nil, beta: nil)
          kwargs = {}
          kwargs[:alpha] = alpha if alpha
          kwargs[:beta] = beta if beta
          new(CombinationMethods::LINEAR, **kwargs)
        end
      end

      class HybridFilter
        attr_reader :args

        def initialize(conditions)
          @args = ["FILTER", conditions]
        end
      end

      class HybridPostProcessingConfig
        def initialize
          @load_statements = []
          @apply_statements = []
          @groupby_statements = []
          @sortby_fields = []
          @filter = nil
          @limit = nil
        end

        def load(*fields)
          if fields.any?
            fields_str = fields.join(" ")
            fields_list = fields_str.split(" ")
            @load_statements.concat(["LOAD", fields_list.size, *fields_list])
          end
          self
        end

        def group_by(fields, *reducers)
          fields = [fields] unless fields.is_a?(Array)
          ret = ["GROUPBY", fields.size.to_s, *fields]
          reducers.each do |reducer|
            ret.concat(["REDUCE", reducer.name, reducer.args.size.to_s])
            ret.concat(reducer.args)
            ret.concat(["AS", reducer.alias_name]) if reducer.alias_name
          end
          @groupby_statements.concat(ret)
          self
        end

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

        def sort_by(*sortby_fields)
          @sortby_fields = sortby_fields
          self
        end

        def filter(flt)
          @filter = flt
          self
        end

        def limit(offset, num)
          @limit = { offset: offset, num: num }
          self
        end

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

      class HybridCursorQuery
        def initialize(count: 0, max_idle: 0)
          @count = count
          @max_idle = max_idle
        end

        def build_args
          args = ["WITHCURSOR"]
          args.concat(["COUNT", @count.to_s]) if @count > 0
          args.concat(["MAXIDLE", @max_idle.to_s]) if @max_idle > 0
          args
        end
      end

      # SortbyField for hybrid search sorting
      class SortbyField
        attr_reader :args

        def initialize(field, asc: true)
          @args = [field, asc ? "ASC" : "DESC"]
        end
      end
    end
  end
end
