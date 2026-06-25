# frozen_string_literal: true

class Redis
  module Commands
    module Search
      # A Redis Query Engine index schema: an ordered collection of {Field}
      # objects rendered into the +SCHEMA+ section of an +FT.CREATE+ call.
      class Schema
        include Enumerable

        attr_reader :fields

        # Build a schema from a list of fields.
        #
        # @param [Array<Field>] fields the fields that make up the schema
        def initialize(fields = [])
          @fields = fields
        end

        # Find a field by name.
        #
        # @param [String, Symbol] name the field name to look up
        # @return [Field, nil] the matching field, or +nil+ if none matches
        def field(name)
          @fields.find { |f| f.name.to_s == name.to_s }
        end

        # Iterate over the schema's fields.
        #
        # @yieldparam [Field] field each field in order
        # @return [Enumerator, Array<Field>] the fields when no block is given
        def each(&block)
          @fields.each(&block)
        end

        # Render the schema as the array of +FT.CREATE+ tokens.
        #
        # @example
        #   schema.to_args # => ["SCHEMA", "title", "TEXT", "SORTABLE"]
        #
        # @return [Array] the +SCHEMA+ keyword followed by each field's tokens
        def to_args
          ['SCHEMA'] + @fields.flat_map(&:to_args)
        end

        # Build a schema using the block DSL evaluated in a {SchemaDefinition}.
        #
        # @example
        #   Redis::Commands::Search::Schema.build do
        #     text_field "title", weight: 5.0, sortable: true
        #     numeric_field "price"
        #   end
        #
        # @return [Schema] the schema built from the block
        # @raise [Redis::CommandError] if a field is given invalid options
        def self.build(&block)
          definition = SchemaDefinition.new
          begin
            definition.instance_eval(&block)
          rescue ArgumentError => e
            raise Redis::CommandError, e.message
          end
          new(definition.fields)
        end
      end

      # The block DSL used by {Schema.build} to declare fields. Each helper
      # appends a {Field} subclass to {#fields}.
      class SchemaDefinition
        attr_reader :fields

        def initialize
          @fields = []
        end

        # Add a {TextField} to the schema.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @option options [Numeric] :weight the field's scoring weight
        # @option options [Boolean] :sortable allow sorting by the field
        # @option options [Boolean] :no_index do not index the field
        # @option options [String] :as an alias for the field
        # @option options [String] :phonetic phonetic matcher
        # @option options [Boolean] :no_stem disable stemming
        # @option options [Boolean] :index_empty index empty values
        # @option options [Boolean] :withsuffixtrie build a suffix trie
        # @return [Array<Field>] the updated field list
        # @raise [ArgumentError] if an unknown option key is given
        def text_field(name, **options)
          valid_options = %i[weight sortable no_index as phonetic no_stem index_empty index_missing withsuffixtrie]
          invalid_options = options.keys - valid_options
          if invalid_options.any?
            raise ArgumentError, "Invalid options for text field: #{invalid_options.join(', ')}"
          end

          @fields << TextField.new(name, **options)
        end

        # Add a {NumericField} to the schema.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @return [Array<Field>] the updated field list
        def numeric_field(name, **options)
          @fields << NumericField.new(name, **options)
        end

        # Add a {TagField} to the schema.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @option options [Boolean] :sortable allow sorting by the field
        # @option options [Boolean] :no_index do not index the field
        # @option options [String] :as an alias for the field
        # @option options [String] :separator the tag separator character
        # @option options [Boolean] :case_sensitive keep tag casing
        # @option options [Boolean] :index_empty index empty values
        # @option options [Boolean] :index_missing index documents missing the field
        # @option options [Boolean] :withsuffixtrie build a suffix trie
        # @return [Array<Field>] the updated field list
        # @raise [ArgumentError] if an unknown option key is given
        def tag_field(name, **options)
          valid_options = %i[sortable no_index as separator case_sensitive index_empty index_missing withsuffixtrie]
          invalid_options = options.keys - valid_options
          if invalid_options.any?
            raise ArgumentError, "Invalid options for tag field: #{invalid_options.join(', ')}"
          end

          @fields << TagField.new(name, **options)
        end

        # Add a {GeoField} to the schema.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @return [Array<Field>] the updated field list
        def geo_field(name, **options)
          @fields << GeoField.new(name, **options)
        end

        # Add a {GeoShapeField} to the schema.
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [String] coord_system the coordinate system, +FLAT+ or +SPHERICAL+
        # @return [Array<Field>] the updated field list
        def geoshape_field(name, coord_system = GeoShapeField::FLAT, **options)
          @fields << GeoShapeField.new(name, coord_system, **options)
        end

        # Add a {VectorField} to the schema.
        #
        # Field-level options (+:as+, +:sortable+, +:no_index+) are extracted from
        # +attributes+; the remaining keys (e.g. +type:+, +dim:+, +distance_metric:+)
        # become vector attributes. An optional block is evaluated in a
        # {VectorFieldDefinition} for declaring attributes.
        #
        # @example
        #   vector_field "embedding", "HNSW", type: "FLOAT32", dim: 4, distance_metric: "L2"
        #
        # @param [String, Symbol] name the document attribute the field indexes
        # @param [String, Symbol] algorithm the indexing method (+FLAT+, +HNSW+, +SVS-VAMANA+)
        # @param [Hash] attributes vector attributes and field-level options
        # @yield an optional block evaluated in a {VectorFieldDefinition}
        # @return [Array<Field>] the updated field list
        def vector_field(name, algorithm, **attributes, &block)
          # Extract field-level options (as, sortable, no_index) from attributes
          field_options = {}
          field_options[:as] = attributes.delete(:as) if attributes.key?(:as)
          field_options[:sortable] = attributes.delete(:sortable) if attributes.key?(:sortable)
          field_options[:no_index] = attributes.delete(:no_index) if attributes.key?(:no_index)

          field = VectorField.new(name, algorithm, attributes, **field_options)
          VectorFieldDefinition.new(field).instance_eval(&block) if block_given?
          @fields << field
        end
      end

      # The block DSL used by {SchemaDefinition#vector_field} to declare the
      # attributes of a {VectorField}.
      class VectorFieldDefinition
        def initialize(field)
          @field = field
        end

        # Set the vector element type attribute (e.g. +FLOAT32+).
        #
        # @param [Object] value the +TYPE+ attribute value
        # @return [Object] the stored value
        def type(value)
          @field.add_attribute(:type, value)
        end

        # Set the vector dimensionality attribute.
        #
        # @param [Object] value the +DIM+ attribute value
        # @return [Object] the stored value
        def dim(value)
          @field.add_attribute(:dim, value)
        end

        # Set the distance metric attribute (e.g. +L2+, +COSINE+).
        #
        # @param [Object] value the +DISTANCE_METRIC+ attribute value
        # @return [Object] the stored value
        def distance_metric(value)
          @field.add_attribute(:distance_metric, value)
        end
      end
    end
  end
end
