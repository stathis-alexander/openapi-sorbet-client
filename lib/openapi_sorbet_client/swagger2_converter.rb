# frozen_string_literal: true

require "set"

module OpenapiSorbetClient
  # Normalizes Swagger / OpenAPI 2.0 documents into an OpenAPI 3-shaped Hash
  # so the existing Parser can build IR without a second dialect.
  class Swagger2Converter
    HTTP_METHODS = %w[get put post delete options head patch].freeze

    def self.convert(document)
      new(document).convert
    end

    def initialize(document)
      @document = deep_dup(document)
    end

    def convert
      raise StandardError, "Swagger document must contain an object" unless @document.is_a?(Hash)
      raise StandardError, "Expected swagger: \"2.0\"" unless swagger2?

      rewrite_refs!(@document)
      {
        "openapi" => "3.0.3",
        "info" => @document["info"] || {},
        "servers" => convert_servers,
        "paths" => convert_paths(@document["paths"] || {}),
        "components" => {
          "schemas" => convert_schemas(@document["definitions"] || {}),
          "securitySchemes" => convert_security_definitions(@document["securityDefinitions"] || {})
        },
        "security" => @document["security"]
      }.compact
    end

    private

    def swagger2?
      @document["swagger"].to_s.start_with?("2.")
    end

    def convert_servers
      host = @document["host"]
      return [] if host.nil? || host.to_s.empty?

      scheme = Array(@document["schemes"]).first || "https"
      base_path = @document["basePath"].to_s
      base_path = "/#{base_path}" unless base_path.empty? || base_path.start_with?("/")
      [{ "url" => "#{scheme}://#{host}#{base_path}" }]
    end

    def convert_schemas(definitions)
      definitions.transform_values { |definition| convert_schema(definition) }
    end

    def convert_schema(definition)
      return definition unless definition.is_a?(Hash)

      converted = definition.each_with_object({}) do |(key, value), result|
        result[key] = case key
                      when "properties"
                        value.transform_values { |property| convert_schema(property) }
                      when "items", "additionalProperties"
                        value.is_a?(Hash) ? convert_schema(value) : value
                      when "allOf", "oneOf", "anyOf"
                        Array(value).map { |member| convert_schema(member) }
                      else
                        deep_dup(value)
                      end
      end

      if converted.key?("x-nullable")
        converted["nullable"] = converted.delete("x-nullable") == true
      end
      converted
    end

    def convert_security_definitions(definitions)
      definitions.transform_values do |definition|
        case definition["type"]
        when "basic"
          {
            "type" => "http",
            "scheme" => "basic",
            "description" => definition["description"]
          }.compact
        when "oauth2"
          # Keep a minimal oauth2 placeholder; v1 emitter mainly uses apiKey.
          {
            "type" => "oauth2",
            "description" => definition["description"],
            "flows" => {}
          }.compact
        else
          deep_dup(definition)
        end
      end
    end

    def convert_paths(paths)
      paths.transform_values do |path_item|
        next path_item unless path_item.is_a?(Hash)

        converted = {}
        path_parameters = Array(path_item["parameters"])
        converted["parameters"] = convert_non_body_parameters(path_parameters) if path_parameters.any?

        path_item.each do |key, value|
          next if key == "parameters"

          if HTTP_METHODS.include?(key.to_s)
            converted[key] = convert_operation(value, path_parameters)
          else
            converted[key] = deep_dup(value)
          end
        end
        converted
      end
    end

    def convert_operation(operation, _path_parameters)
      return operation unless operation.is_a?(Hash)

      parameters = Array(operation["parameters"])
      consumes = Array(operation["consumes"])
      consumes = Array(@document["consumes"]) if consumes.empty?
      produces = Array(operation["produces"])
      produces = Array(@document["produces"]) if produces.empty?

      converted = except_keys(operation, %w[parameters consumes produces responses])
      non_body = convert_non_body_parameters(parameters)
      converted["parameters"] = non_body if non_body.any?

      request_body = convert_request_body(parameters, consumes)
      converted["requestBody"] = request_body if request_body

      converted["responses"] = convert_responses(operation["responses"] || {}, produces)
      converted
    end

    def convert_non_body_parameters(parameters)
      parameters.filter_map do |parameter|
        next unless parameter.is_a?(Hash)
        next if %w[body formData].include?(parameter["in"])

        convert_parameter(parameter)
      end
    end

    def convert_parameter(parameter)
      schema_keys = %w[type format items enum minimum maximum exclusiveMinimum exclusiveMaximum
                       minLength maxLength pattern minItems maxItems uniqueItems multipleOf default]
      drop_keys = schema_keys + %w[collectionFormat x-nullable]
      converted = except_keys(parameter, drop_keys)
      schema = select_keys(parameter, schema_keys)
      schema = convert_schema(schema) if schema.any?
      if parameter.key?("x-nullable")
        schema = schema.merge("nullable" => parameter["x-nullable"] == true)
      end
      if schema.any?
        converted["schema"] = schema
      elsif parameter["schema"]
        converted["schema"] = convert_schema(parameter["schema"])
      else
        converted["schema"] = { "type" => "string" }
      end
      converted
    end
    def convert_request_body(parameters, consumes)
      body = parameters.find { |parameter| parameter.is_a?(Hash) && parameter["in"] == "body" }
      form_params = parameters.select { |parameter| parameter.is_a?(Hash) && parameter["in"] == "formData" }

      if body
        content_type = preferred_content_type(consumes, default: "application/json")
        return {
          "required" => body["required"] == true,
          "content" => {
            content_type => {
              "schema" => convert_schema(body["schema"] || {})
            }
          }
        }
      end

      return if form_params.empty?

      content_type = if form_params.any? { |parameter| parameter["type"] == "file" } ||
                        consumes.include?("multipart/form-data")
                       "multipart/form-data"
                     else
                       preferred_content_type(
                         consumes & ["application/x-www-form-urlencoded", "multipart/form-data"],
                         default: "application/x-www-form-urlencoded"
                       )
                     end

      properties = {}
      required = []
      form_params.each do |parameter|
        name = parameter.fetch("name")
        properties[name] = convert_parameter(parameter).fetch("schema")
        required << name if parameter["required"] == true
      end

      {
        "required" => required.any?,
        "content" => {
          content_type => {
            "schema" => {
              "type" => "object",
              "properties" => properties,
              "required" => required
            }.compact
          }
        }
      }
    end

    def convert_responses(responses, produces)
      responses.transform_values do |response|
        next response unless response.is_a?(Hash)
        next deep_dup(response) unless response.key?("schema")

        content_type = preferred_content_type(produces, default: "application/json")
        converted = except_keys(response, %w[schema examples])
        converted["content"] = {
          content_type => {
            "schema" => convert_schema(response["schema"])
          }
        }
        converted
      end
    end

    def preferred_content_type(candidates, default:)
      list = Array(candidates)
      return "application/json" if list.include?("application/json")
      return "text/json" if list.include?("text/json")
      return list.first if list.any?

      default
    end

    def rewrite_refs!(node)
      case node
      when Hash
        if node["$ref"].is_a?(String)
          node["$ref"] = node["$ref"].sub(%r{\A#/definitions/}, "#/components/schemas/")
        end
        node.each_value { |value| rewrite_refs!(value) }
      when Array
        node.each { |value| rewrite_refs!(value) }
      end
    end

    def deep_dup(value)
      case value
      when Hash
        value.transform_values { |child| deep_dup(child) }
      when Array
        value.map { |child| deep_dup(child) }
      else
        value
      end
    end

    def except_keys(hash, keys)
      excluded = keys.to_set
      hash.reject { |key, _value| excluded.include?(key) }
    end

    def select_keys(hash, keys)
      allowed = keys.to_set
      hash.select { |key, _value| allowed.include?(key) }
    end
  end
end
