# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class IndexDefinition
        attr_reader :args

        def initialize(
          prefix: [], filter: nil, language_field: nil, language: nil,
          score_field: nil, score: 1.0, payload_field: nil, index_type: nil
        )
          @args = []
          append_index_type(index_type)
          append_prefix(prefix)
          append_filter(filter)
          append_language(language_field, language)
          append_score(score_field, score)
          append_payload(payload_field)
        end

        private

        def append_index_type(index_type)
          if index_type == IndexType::HASH
            @args += ["ON", "HASH"]
          elsif index_type == IndexType::JSON
            @args += ["ON", "JSON"]
          elsif !index_type.nil?
            raise ArgumentError, "index_type must be IndexType::HASH or IndexType::JSON"
          end
        end

        def append_prefix(prefix)
          unless prefix.empty?
            @args << "PREFIX"
            @args << prefix.length
            prefix.each { |p| @args << p }
          end
        end

        def append_filter(filter)
          if filter
            @args << "FILTER"
            @args << filter
          end
        end

        def append_language(language_field, language)
          if language_field
            @args << "LANGUAGE_FIELD"
            @args << language_field
          end
          if language
            @args << "LANGUAGE"
            @args << language
          end
        end

        def append_score(score_field, score)
          if score_field
            @args << "SCORE_FIELD"
            @args << score_field
          end
          if score
            @args << "SCORE"
            @args << score
          end
        end

        def append_payload(payload_field)
          if payload_field
            @args << "PAYLOAD_FIELD"
            @args << payload_field
          end
        end
      end
    end
  end
end
