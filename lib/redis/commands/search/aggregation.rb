# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class AggregateRequest
        def initialize(query = "*", with_cursor: false, cursor_count: nil, cursor_max_idle: nil, dialect: nil)
          @query = query
          @with_cursor = with_cursor
          @cursor_count = cursor_count
          @cursor_max_idle = cursor_max_idle
          @dialect = dialect
          @steps = []
        end

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

        def apply(expressions)
          expressions.each do |as, expression|
            @steps << ["APPLY", expression, "AS", as.to_s]
          end
          self
        end

        def limit(offset, num)
          @steps << ["LIMIT", offset, num]
          self
        end

        def filter(expression)
          @steps << ["FILTER", expression]
          self
        end

        def load(*fields)
          @steps << if fields.empty?
            ["LOAD", "*"]
          else
            ["LOAD", fields.size, *fields].flatten
          end
          self
        end

        def add_scores(add_scores: true)
          @add_scores = add_scores
          self
        end

        def dialect(dialect_version)
          @dialect = dialect_version
          self
        end

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

      # Helper classes for AggregateRequest
      class Asc
        attr_reader :name, :order

        def initialize(name)
          @name = name
          @order = 'ASC'
        end
      end

      class Desc
        attr_reader :name, :order

        def initialize(name)
          @name = name
          @order = 'DESC'
        end
      end

      # Reducers for aggregations
      class Reducers
        def self.count(alias_name: nil)
          new("COUNT", alias_name: alias_name)
        end

        def self.count_distinct(property, alias_name: nil)
          new("COUNT_DISTINCT", property, alias_name: alias_name)
        end

        def self.count_distinctish(property, alias_name: nil)
          new("COUNT_DISTINCTISH", property, alias_name: alias_name)
        end

        def self.sum(property, alias_name: nil)
          new("SUM", property, alias_name: alias_name)
        end

        def self.min(property, alias_name: nil)
          new("MIN", property, alias_name: alias_name)
        end

        def self.max(property, alias_name: nil)
          new("MAX", property, alias_name: alias_name)
        end

        def self.avg(property, alias_name: nil)
          new("AVG", property, alias_name: alias_name)
        end

        def self.stddev(property, alias_name: nil)
          new("STDDEV", property, alias_name: alias_name)
        end

        def self.quantile(property, quantile, alias_name: nil)
          new("QUANTILE", property, quantile, alias_name: alias_name)
        end

        def self.tolist(property, alias_name: nil)
          new("TOLIST", property, alias_name: alias_name)
        end

        def self.first_value(property, alias_name: nil, sort_by: nil, sort_order: nil)
          args = [property]
          if sort_by
            args << "BY" << sort_by
            args << (sort_order || "ASC").to_s.upcase
          end
          new("FIRST_VALUE", *args, alias_name: alias_name)
        end

        def self.random_sample(property, sample_size, alias_name: nil)
          new("RANDOM_SAMPLE", property, sample_size, alias_name: alias_name)
        end

        attr_reader :name, :args, :alias_name

        def initialize(name, *args, alias_name: nil)
          @name = name
          @args = args
          @alias_name = alias_name
        end

        def as(alias_name)
          @alias_name = alias_name
          self
        end
      end

      # Cursor for aggregation pagination
      class Cursor
        attr_accessor :cid, :max_idle, :count

        def initialize(cid)
          @cid = cid
          @max_idle = 0
          @count = 0
        end

        def build_args
          args = [@cid.to_s]
          args.concat(["MAXIDLE", @max_idle.to_s]) if @max_idle > 0
          args.concat(["COUNT", @count.to_s]) if @count > 0
          args
        end
      end
    end
  end
end
