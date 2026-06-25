# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # Base class for a single field in a Redis Query Engine +SCHEMA+ (the
      # field list passed to +FT.CREATE+). Subclasses describe the field type
      # (+TEXT+, +TAG+, +NUMERIC+, +GEO+, +GEOSHAPE+, +VECTOR+).
      class Field
        attr_reader :name, :type, :options, :alias_name
        attr_accessor :query

        # Build a field definition.
        #
        # @example
        #   Redis::Commands::Search::Field.new("title", :text, weight: 5.0, sortable: true)
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [Symbol] type the field type, e.g. +:text+, +:tag+, +:numeric+
        # @param [Query, nil] query a query the field is bound to, enabling predicate helpers
        # @option options [String] :as an alias for the field, rendered as +AS <alias>+
        # @option options [Boolean] :no_index do not index the field (+NOINDEX+)
        # @option options [Boolean] :index_missing index documents missing the field (+INDEXMISSING+)
        # @option options [Boolean] :index_empty index empty values (+INDEXEMPTY+)
        # @option options [Boolean] :sortable allow sorting by the field (+SORTABLE+)
        # @option options [Boolean] :withsuffixtrie build a suffix trie (+WITHSUFFIXTRIE+)
        def initialize(name, type, query = nil, **options)
          @name = name.to_s
          @type = type
          @query = query
          @options = options
          @alias_name = options.delete(:as)
        end

        # Render this field as the array of +FT.CREATE+ +SCHEMA+ tokens.
        #
        # @example
        #   Redis::Commands::Search::Field.new("title", :text, weight: 5.0, sortable: true).to_args
        #     # => ["title", "TEXT", "WEIGHT", "5.0", "SORTABLE"]
        #
        # @return [Array] the schema tokens for this field
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

      # A +TAG+ field, indexing one or more delimited tag tokens.
      class TagField < Field
        # Build a +TAG+ field.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [Query, nil] query a query the field is bound to, enabling {#eq}
        # @option options [String] :separator the tag separator character (+SEPARATOR+)
        # @option options [Boolean] :case_sensitive keep tag casing (+CASESENSITIVE+)
        def initialize(name, query = nil, **options)
          super(name, :tag, query, **options)
        end

        # Add a tag-equality predicate (+@field:{value}+) to the bound query.
        #
        # @param [String] value the tag to match
        # @return [Query] the bound query with the predicate added
        def eq(value)
          query.add_predicate(TagEqualityPredicate.new(@alias || name, value))
        end
      end

      # A +TEXT+ field, indexing full-text searchable content.
      class TextField < Field
        # Build a +TEXT+ field.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [Query, nil] query a query the field is bound to, enabling {#match}
        # @option options [Numeric] :weight the field's scoring weight (+WEIGHT+)
        # @option options [String] :phonetic phonetic matcher, one of +dm:en+, +dm:fr+, +dm:pt+, +dm:es+ (+PHONETIC+)
        # @option options [Boolean] :no_stem disable stemming (+NOSTEM+)
        # @raise [ArgumentError] if +:phonetic+ is not a supported matcher
        def initialize(name, query = nil, **options)
          super(name, :text, query, **options)
          if options[:phonetic]
            valid_matchers = ['dm:en', 'dm:fr', 'dm:pt', 'dm:es']
            unless valid_matchers.include?(options[:phonetic])
              raise ArgumentError, "Invalid phonetic matcher. Supported matchers are: #{valid_matchers.join(', ')}"
            end
          end
        end

        # Render this field as the array of +FT.CREATE+ +SCHEMA+ tokens.
        #
        # @return [Array] the schema tokens for this field
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

        # Add a text-match predicate (+@field:pattern+) to the bound query.
        #
        # @param [String] pattern the text pattern to match
        # @return [Query] the bound query with the predicate added
        def match(pattern)
          query.add_predicate(TextMatchPredicate.new(@alias || name, pattern))
        end
      end

      # A +NUMERIC+ field, indexing numeric values for range queries.
      class NumericField < Field
        # Build a +NUMERIC+ field.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [Query, nil] query a query the field is bound to, enabling {#gt}, {#lt}, {#between}
        def initialize(name, query = nil, **options)
          super(name, :numeric, query, **options)
        end

        # Add a greater-than range predicate to the bound query.
        #
        # @param [Numeric] value the exclusive lower bound
        # @return [Query] the bound query with the predicate added
        def gt(value)
          query.add_predicate(RangePredicate.new(@alias || name, "(#{value}", "+inf"))
        end

        # Add a less-than range predicate to the bound query.
        #
        # @param [Numeric] value the exclusive upper bound
        # @return [Query] the bound query with the predicate added
        def lt(value)
          query.add_predicate(RangePredicate.new(@alias || name, "-inf", "(#{value}"))
        end

        # Add an inclusive range predicate to the bound query.
        #
        # @param [Numeric] min the inclusive lower bound
        # @param [Numeric] max the inclusive upper bound
        # @return [Query] the bound query with the predicate added
        def between(min, max)
          query.add_predicate(RangePredicate.new(@alias || name, min, max))
        end
      end

      # A +GEO+ field, indexing longitude/latitude pairs for geo queries.
      class GeoField < Field
        # Build a +GEO+ field.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [Query, nil] query a query the field is bound to
        def initialize(name, query = nil, **options)
          super(name, :geo, query, **options)
        end
      end

      # A +GEOSHAPE+ field, indexing geometric shapes under a coordinate system.
      class GeoShapeField < Field
        FLAT = "FLAT"
        SPHERICAL = "SPHERICAL"

        # Build a +GEOSHAPE+ field.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [String] coord_system the coordinate system, {FLAT} or {SPHERICAL}
        def initialize(name, coord_system = FLAT, **options)
          super(name, :geoshape, nil, **options)
          @coord_system = coord_system
        end

        # Render this field as the array of +FT.CREATE+ +SCHEMA+ tokens.
        #
        # @return [Array] the schema tokens for this field
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

      # A +VECTOR+ field, indexing embeddings for approximate/exact nearest-neighbor search.
      class VectorField < Field
        attr_reader :algorithm, :attributes

        # Build a +VECTOR+ field.
        #
        # @example
        #   Redis::Commands::Search::Field::VectorField.new(
        #     "embedding", "HNSW", { type: "FLOAT32", dim: 4, distance_metric: "L2" }
        #   )
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [String, Symbol] algorithm the indexing method, one of +FLAT+, +HNSW+, +SVS-VAMANA+
        # @param [Hash] attributes the vector attributes (e.g. +type+, +dim+, +distance_metric+)
        # @option options [String] :as an alias for the field, rendered as +AS <alias>+
        # @raise [ArgumentError] if +algorithm+ is not a supported indexing method
        # @raise [Redis::CommandError] if +:sortable+ or +:no_index+ is given
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

        # Set or override a single vector attribute.
        #
        # @param [String, Symbol] key the attribute name (upcased internally)
        # @param [Object] value the attribute value
        # @return [Object] the stored value
        def add_attribute(key, value)
          @attributes[key.to_s.upcase] = value
        end

        # Render this field as the array of +FT.CREATE+ +SCHEMA+ tokens.
        #
        # @return [Array] the schema tokens for this field, including the +VECTOR+ clause
        def to_args
          args = [name]
          args << "AS" << @alias_name if @alias_name
          args += field_args
          args
        end

        # Returns field-specific args (without name/alias) for compatibility with tests
        #
        # @return [Array] the +VECTOR+ clause tokens (without name/alias)
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
