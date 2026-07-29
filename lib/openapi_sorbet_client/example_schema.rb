# frozen_string_literal: true

require "json"

module OpenapiSorbetClient
  # Builds OpenAPI-shaped schema Hashes from media-type examples when a
  # formal schema is missing.
  module ExampleSchema
    module_function

    def from_media_type(media_type)
      example = extract_example(media_type)
      return if example.nil?

      schema_from_value(example)
    end

    def extract_example(media_type)
      return unless media_type.is_a?(Hash)

      if media_type.key?("example")
        return coerce_example(media_type["example"])
      end

      examples = media_type["examples"]
      return unless examples.is_a?(Hash) && examples.any?

      first = examples.values.first
      value = first.is_a?(Hash) && first.key?("value") ? first["value"] : first
      coerce_example(value)
    end

    def coerce_example(value)
      return value unless value.is_a?(String)

      trimmed = value.strip
      return value unless trimmed.start_with?("{", "[")

      JSON.parse(trimmed)
    rescue JSON::ParserError
      value
    end

    def schema_from_value(value)
      case value
      when Hash
        object_schema(value)
      when Array
        array_schema(value)
      when TrueClass, FalseClass
        { "type" => "boolean" }
      when Integer
        { "type" => "integer" }
      when Float
        { "type" => "number" }
      when NilClass
        { "type" => "string", "nullable" => true }
      else
        { "type" => "string" }
      end
    end

    def object_schema(hash)
      properties = {}
      required = []
      hash.each do |key, child|
        wire_key = key.to_s
        properties[wire_key] = schema_from_value(child)
        required << wire_key
      end
      {
        "type" => "object",
        "properties" => properties,
        "required" => required
      }
    end

    def array_schema(array)
      item_schema = if array.empty?
                      { "type" => "string" }
                    else
                      schema_from_value(array.first)
                    end
      {
        "type" => "array",
        "items" => item_schema
      }
    end
  end
end
