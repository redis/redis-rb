# frozen_string_literal: true

class Redis
  module Commands
    module Search
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
          args += definition.args
        else
          args += ["ON", storage_type] if storage_type
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

        call('FT.CREATE', *args)
      end

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

      def ft_search(index_name, query, **options)
        args = [index_name, query]

        args << "NOCONTENT" if options[:no_content]
        args << "VERBATIM" if options[:verbatim]
        args << "NOSTOPWORDS" if options[:no_stopwords]
        args << "WITHSCORES" if options[:with_scores]
        args << "WITHPAYLOADS" if options[:with_payloads]
        args << "SCORER" << options[:scorer] if options[:scorer]
        args << "EXPLAINSCORE" if options[:explain_score]
        args << "LANGUAGE" << options[:language] if options[:language]
        args << "SLOP" << options[:slop] if options[:slop]
        args << "INORDER" if options[:in_order]
        args << "LIMIT" << options[:limit][0] << options[:limit][1] if options[:limit]

        # Handle both :sortby (array format) and :sort_by (convenience format)
        if options[:sortby]
          args << "SORTBY" << options[:sortby][0] << options[:sortby][1]
        elsif options[:sort_by]
          direction = options[:asc] ? 'ASC' : 'DESC'
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

        args << "DIALECT" << options[:dialect] if options[:dialect]

        send_command(["FT.SEARCH"] + args.flatten.compact)
      end

      def ft_add(index_name, doc_id, score, options = {})
        args = ["FT.ADD", index_name, doc_id, score]
        args << 'REPLACE' if options[:replace]
        args << 'LANGUAGE' << options[:language] if options[:language]
        args << 'FIELDS' << options[:fields] if options[:fields]
        send_command(args)
      end

      def ft_info(index_name)
        result = send_command(["FT.INFO", index_name])
        result.each_slice(2).to_h
      end

      def ft_dropindex(index_name, delete_documents: false)
        args = ["FT.DROPINDEX", index_name]
        args << 'DD' if delete_documents
        send_command(args)
      end

      def ft_del(index_name, doc_id)
        send_command(["FT.DEL", index_name, doc_id])
      end

      def ft_mget(index_name, *doc_ids)
        send_command(["FT.MGET", index_name] + doc_ids)
      end

      def ft_aggregate(index_name, query, *args)
        case query
        when AggregateRequest
          send_command(["FT.AGGREGATE", index_name] + query.to_redis_args)
        when Cursor
          send_command(["FT.CURSOR", "READ", index_name] + query.build_args)
        else
          send_command(["FT.AGGREGATE", index_name, query, *args])
        end
      end

      def ft_explain(index_name, query)
        send_command(["FT.EXPLAIN", index_name, query])
      end

      def ft_alter(index_name, field_or_args)
        args = [index_name, "SCHEMA", "ADD"]
        if field_or_args.respond_to?(:to_args)
          args += field_or_args.to_args
        elsif field_or_args.is_a?(Array)
          args += field_or_args
        else
          raise ArgumentError, "field_or_args must be a Field object or an array"
        end
        call("FT.ALTER", *args)
      end

      def ft_cursor_read(index_name, cursor_id)
        send_command(["FT.CURSOR", "READ", index_name, cursor_id])
      end

      def ft_cursor_del(index_name, cursor_id)
        send_command(["FT.CURSOR", "DEL", index_name, cursor_id])
      end

      def ft_profile(index_name, *args)
        send_command(["FT.PROFILE", index_name] + args)
      end

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
        send_command(args)
      end

      def ft_sugadd(key, string, score, options = {})
        args = ["FT.SUGADD", key, string, score]
        args << 'INCR' if options[:incr]
        args << 'PAYLOAD' << options[:payload] if options[:payload]
        send_command(args)
      end

      def ft_sugget(key, prefix, options = {})
        args = ["FT.SUGGET", key, prefix]
        args << 'FUZZY' if options[:fuzzy]
        args << 'WITHSCORES' if options[:withscores] || options[:with_scores]
        args << 'WITHPAYLOADS' if options[:withpayloads] || options[:with_payloads]
        args << 'MAX' << options[:max] if options[:max]
        send_command(args)
      end

      def ft_suglen(key)
        send_command(["FT.SUGLEN", key])
      end

      def ft_sugdel(key, string)
        send_command(["FT.SUGDEL", key, string])
      end

      def ft_spellcheck(index_name, query, distance: nil, include: nil, exclude: nil, parse: false)
        args = ["FT.SPELLCHECK", index_name, query]
        args += ["DISTANCE", distance] if distance

        if include
          args += ["TERMS", "INCLUDE", include]
        end

        if exclude
          args += ["TERMS", "EXCLUDE", exclude]
        end

        result = send_command(args)

        return result unless parse

        # Parse result into hash: { term => [{ suggestion: ..., score: ... }] }
        parsed = {}
        result.each do |entry|
          next unless entry[0] == "TERM"

          term = entry[1]
          suggestions = entry[2].map do |score, suggestion|
            { 'score' => score, 'suggestion' => suggestion }
          end
          parsed[term] = suggestions
        end
        parsed
      end

      def ft_synupdate(index_name, group_id, *terms, skip_initial_scan: false)
        args = [index_name, group_id]
        args << "SKIPINITIALSCAN" if skip_initial_scan
        args += terms
        send_command(["FT.SYNUPDATE"] + args)
      end

      def ft_syndump(index_name)
        result = send_command(["FT.SYNDUMP", index_name])
        # Parse result into hash: { term => [group_ids] }
        Hash[*result]
      end

      def ft_tagvals(index_name, field_name)
        send_command(["FT.TAGVALS", index_name, field_name])
      end

      def ft_aliasadd(alias_name, index_name)
        send_command(["FT.ALIASADD", alias_name, index_name])
      end

      def ft_aliasupdate(alias_name, index_name)
        send_command(["FT.ALIASUPDATE", alias_name, index_name])
      end

      def ft_aliasdel(alias_name)
        send_command(["FT.ALIASDEL", alias_name])
      end

      def ft_dictadd(dict_name, *terms)
        send_command(["FT.DICTADD", dict_name] + terms)
      end

      def ft_dictdel(dict_name, *terms)
        send_command(["FT.DICTDEL", dict_name] + terms)
      end

      def ft_dictdump(dict_name)
        send_command(["FT.DICTDUMP", dict_name])
      end

      def ft_config_set(option, value)
        send_command(["FT.CONFIG", "SET", option, value])
      end

      def ft_config_get(option)
        result = send_command(["FT.CONFIG", "GET", option])
        # Convert array of [key, value] pairs to hash
        result.to_h
      end
    end
  end
end
