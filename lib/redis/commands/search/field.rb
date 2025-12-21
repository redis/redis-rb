# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class Field
        attr_reader :name, :type, :options, :alias_name
        attr_accessor :query

        def initialize(name, type, query = nil, **options)
          @name = name.to_s
          @type = type
          @query = query
          @options = options
          @alias_name = options.delete(:as)
        end

        def to_args
          args = [@name]
          args << "AS" << @alias_name if @alias_name
          args << @type.to_s.upcase

          # Add type-specific options first (separator, casesensitive for TAG)
          if @type == :tag
            args << "SEPARATOR" << @options[:separator] if @options[:separator]
            args << "CASESENSITIVE" if @options[:case_sensitive]
          end

          # Add suffix options in specific order: no_index, index_missing, index_empty, sortable, withsuffixtrie
          args << "NOINDEX" if @options[:no_index]
          args << "INDEXMISSING" if @options[:index_missing]
          args << "INDEXEMPTY" if @options[:index_empty]
          args << "SORTABLE" if @options[:sortable]
          args << "WITHSUFFIXTRIE" if @options[:withsuffixtrie]

          args
        end
      end

      class TagField < Field
        def initialize(name, query = nil, **options)
          super(name, :tag, query, **options)
        end

        def eq(value)
          query.add_predicate(TagEqualityPredicate.new(@alias || name, value))
        end
      end

      class TextField < Field
        def initialize(name, query = nil, **options)
          super(name, :text, query, **options)
          if options[:phonetic]
            valid_matchers = ['dm:en', 'dm:fr', 'dm:pt', 'dm:es']
            unless valid_matchers.include?(options[:phonetic])
              raise ArgumentError, "Invalid phonetic matcher. Supported matchers are: #{valid_matchers.join(', ')}"
            end
          end
        end

        def to_args
          args = [@name]
          args << "AS" << @alias_name if @alias_name
          args << @type.to_s.upcase
          args << "NOSTEM" if @options[:no_stem]
          args << "WEIGHT" << @options[:weight].to_s if @options[:weight]
          args << "PHONETIC" << @options[:phonetic] if @options[:phonetic]

          # Add suffix options in specific order: no_index, index_missing, index_empty, sortable, withsuffixtrie
          args << "NOINDEX" if @options[:no_index]
          args << "INDEXMISSING" if @options[:index_missing]
          args << "INDEXEMPTY" if @options[:index_empty]
          args << "SORTABLE" if @options[:sortable]
          args << "WITHSUFFIXTRIE" if @options[:withsuffixtrie]

          args
        end

        def match(pattern)
          query.add_predicate(TextMatchPredicate.new(@alias || name, pattern))
        end
      end

      class NumericField < Field
        def initialize(name, query = nil, **options)
          super(name, :numeric, query, **options)
        end

        def gt(value)
          query.add_predicate(RangePredicate.new(@alias || name, "(#{value}", "+inf"))
        end

        def lt(value)
          query.add_predicate(RangePredicate.new(@alias || name, "-inf", "(#{value}"))
        end

        def between(min, max)
          query.add_predicate(RangePredicate.new(@alias || name, min, max))
        end
      end

      class GeoField < Field
        def initialize(name, query = nil, **options)
          super(name, :geo, query, **options)
        end
      end

      class GeoShapeField < Field
        FLAT = "FLAT"
        SPHERICAL = "SPHERICAL"

        def initialize(name, coord_system = FLAT, **options)
          super(name, :geoshape, nil, **options)
          @coord_system = coord_system
        end

        def to_args
          args = [@name]
          args << "AS" << @alias_name if @alias_name
          args << @type.to_s.upcase
          args << @coord_system

          # Add suffix options
          args << "NOINDEX" if @options[:no_index]
          args << "SORTABLE" if @options[:sortable]

          args
        end
      end

      class VectorField < Field
        attr_reader :algorithm, :attributes

        def initialize(name, algorithm, attributes = {}, **options)
          # Validate algorithm
          unless ['FLAT', 'HNSW', 'SVS-VAMANA'].include?(algorithm.to_s.upcase)
            raise ArgumentError,
                  "Realtime vector indexing supporting 3 Indexing Methods: 'FLAT', 'HNSW', and 'SVS-VAMANA'"
          end

          # Validate that sortable and no_index are not used with vector fields
          if options[:sortable]
            raise Redis::CommandError, "Vector fields cannot be sortable"
          end
          if options[:no_index]
            raise Redis::CommandError, "Vector fields cannot have no_index option"
          end

          super(name, :vector, **options)
          @algorithm = algorithm.to_s.upcase
          @attributes = attributes.transform_keys { |k| k.to_s.upcase }.transform_values { |v| v.to_s.upcase }
        end

        def add_attribute(key, value)
          @attributes[key.to_s.upcase] = value
        end

        def to_args
          args = [name]
          args << "AS" << @alias_name if @alias_name
          args += field_args
          args
        end

        # Returns field-specific args (without name/alias) for compatibility with tests
        def args
          field_args
        end

        private

        def field_args
          args = ['VECTOR']
          args << @algorithm
          args << @attributes.size * 2
          @attributes.each do |k, v|
            args << k << v
          end
          args
        end
      end
    end
  end
end
