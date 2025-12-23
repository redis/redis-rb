# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class Index
        attr_reader :name, :prefix

        def initialize(redis, name, schema, storage_type, prefix: nil, stopwords: nil)
          @redis = redis
          @name = name
          @prefix = prefix
          @schema = schema
          @storage_type = storage_type
          @stopwords = stopwords
        end

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
          options[:limit_ids] = if query.limit_ids && @prefix
            query.limit_ids.map { |id| "#{@prefix}:#{id}" }
          else
            query.limit_ids
          end

          options[:sortby] = query.options[:sortby]

          # Get dialect from query options or method parameter
          query_dialect = query.options[:dialect]
          options[:dialect] = dialect || query_dialect

          options[:params] = params if params

          options[:return] = query.return_fields

          options[:highlight] = query.highlight_options
          options[:summarize] = query.summarize_options
          options[:verbatim] = query.verbatim
          options[:no_stopwords] = query.no_stopwords
          options[:no_content] = query.no_content
          options[:with_scores] = query.options[:withscores]
          options[:scorer] = query.options[:scorer]
          options[:explain_score] = query.options[:explainscore]
          options[:language] = query.language
          options[:with_payloads] = query.with_payloads
          options[:slop] = query.slop
          options[:in_order] = query.in_order

          if query_params
            options[:params] = query_params
          end

          result = @redis.ft_search(@name, query_string, **options)

          # Strip prefix from document IDs if a prefix is set
          if @prefix
            result[1..-1] = result[1..-1].map do |item|
              item.is_a?(String) ? item.delete_prefix("#{@prefix}:") : item
            end
          end

          result
        end

        def info
          @redis.ft_info(@name)
        end

        def drop(delete_documents: false)
          @redis.ft_dropindex(@name, delete_documents: delete_documents)
        end

        def aggregate(query, *args)
          @redis.ft_aggregate(@name, query, *args)
        end

        def explain(query)
          @redis.ft_explain(@name, query)
        end

        def alter(*args)
          @redis.ft_alter(@name, *args)
        end

        def spellcheck(query, *args)
          @redis.ft_spellcheck(@name, query, *args)
        end

        def synupdate(group_id, *terms, skip_initial_scan: false)
          @redis.ft_synupdate(@name, group_id, skip_initial_scan: skip_initial_scan, terms: terms)
        end

        def syndump
          @redis.ft_syndump(@name)
        end

        def tagvals(field_name)
          @redis.ft_tagvals(@name, field_name)
        end

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
