# frozen_string_literal: true

class Redis
  module Commands
    module Search
      class Schema
        include Enumerable

        attr_reader :fields

        def initialize(fields = [])
          @fields = fields
        end

        def field(name)
          @fields.find { |f| f.name.to_s == name.to_s }
        end

        def each(&block)
          @fields.each(&block)
        end

        def to_args
          ['SCHEMA'] + @fields.flat_map(&:to_args)
        end

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

      class SchemaDefinition
        attr_reader :fields

        def initialize
          @fields = []
        end

        def text_field(name, **options)
          valid_options = %i[weight sortable no_index as phonetic no_stem index_empty withsuffixtrie]
          invalid_options = options.keys - valid_options
          if invalid_options.any?
            raise ArgumentError, "Invalid options for text field: #{invalid_options.join(', ')}"
          end

          @fields << TextField.new(name, **options)
        end

        def numeric_field(name, **options)
          @fields << NumericField.new(name, **options)
        end

        def tag_field(name, **options)
          valid_options = %i[sortable no_index as separator case_sensitive index_empty index_missing withsuffixtrie]
          invalid_options = options.keys - valid_options
          if invalid_options.any?
            raise ArgumentError, "Invalid options for tag field: #{invalid_options.join(', ')}"
          end

          @fields << TagField.new(name, **options)
        end

        def geo_field(name, **options)
          @fields << GeoField.new(name, **options)
        end

        def geoshape_field(name, coord_system = GeoShapeField::FLAT, **options)
          @fields << GeoShapeField.new(name, coord_system, **options)
        end

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

      class VectorFieldDefinition
        def initialize(field)
          @field = field
        end

        def type(value)
          @field.add_attribute(:type, value)
        end

        def dim(value)
          @field.add_attribute(:dim, value)
        end

        def distance_metric(value)
          @field.add_attribute(:distance_metric, value)
        end
      end
    end
  end
end
