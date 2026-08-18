# frozen_string_literal: true

require "psych"

module OpenapiSorbetClient
  # Corrections for cases where a vendor's OpenAPI spec doesn't match the live API's actual
  # behavior. Structural mismatches (wrong field names inside free-text OData $filter values,
  # in practice) can't be caught by validating against the spec itself, since the spec is the
  # thing that's wrong. An overrides file records the observed correct behavior and gets applied
  # to the parsed IR before emission, so a regenerate from an updated vendor spec keeps the fix.
  #
  # File format:
  #   odata_filters:
  #     <operationId>:
  #       param: filter               # existing string kwarg this builds a value for
  #       fields:
  #         - name: tax_year          # snake_case Ruby kwarg
  #           wire_name: TaxYear      # correct OData field name (spec may have this wrong)
  #           required: true
  #         - name: client_id
  #           wire_name: ClientID
  #
  #   schema_constraints:
  #     <SchemaName>:
  #       <property_name>:            # snake_case Ruby prop name
  #         max_length: 30            # live API enforces this; spec doesn't declare it
  class Overrides
    class << self
      def load(path)
        return new({}) if path.nil?

        new(Psych.safe_load(File.read(path)) || {})
      end
    end

    def initialize(source)
      @odata_filters = (source["odata_filters"] || {}).to_h do |operation_id, definition|
        [operation_id, parse_odata_filter(definition)]
      end
      @schema_constraints = source["schema_constraints"] || {}
    end

    def apply(document)
      operations = document.operations.map do |operation|
        filter = @odata_filters[operation.operation_id]
        next operation unless filter

        operation.odata_filter = filter
        operation
      end
      document.operations = operations

      document.schemas.each_value { |schema| apply_schema_constraints(schema) }

      document
    end

    private

    def parse_odata_filter(definition)
      fields = Array(definition["fields"]).map do |field|
        IR::ODataFilterField.new(
          name: field.fetch("name"),
          wire_name: field.fetch("wire_name"),
          required: field["required"] == true
        )
      end

      IR::ODataFilter.new(
        param_name: definition.fetch("param"),
        fields: fields
      )
    end

    def apply_schema_constraints(schema)
      constraints = @schema_constraints[schema.name]
      return if constraints.nil? || schema.properties.nil?

      schema.properties.each do |property|
        property_constraints = constraints[property.name]
        next unless property_constraints

        property.max_length = property_constraints["max_length"]
      end
    end
  end
end
