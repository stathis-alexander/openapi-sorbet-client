# frozen_string_literal: true

require "json"
require "psych"
require "set"

module OpenapiSorbetClient
  class Parser
    COMPONENT_REF = %r{\A#/components/schemas/([^/]+)\z}
    PRIMITIVE_TYPES = {
      "string" => "String",
      "integer" => "Integer",
      "number" => "Float",
      "boolean" => "T::Boolean"
    }.freeze
    HTTP_METHODS = %w[get put post delete options head patch trace].freeze
    REQUEST_CONTENT_TYPE_KEYS = %w[
      application/json
      text/json
      multipart/form-data
      application/x-www-form-urlencoded
    ].freeze

    class << self
      def parse(path)
        new(path).parse
      end
    end

    def initialize(path)
      @path = path
      @schema_definitions = {}
      @schemas = {}
      @resolving = Set.new
    end

    def parse
      source = normalize_source(load_source)
      validate_version!(source)
      @schema_definitions = source.dig("components", "schemas") || {}
      @schema_definitions.each_key { |name| component_schema(name) }

      IR::Document.new(
        title: source.dig("info", "title"),
        version: source.dig("info", "version"),
        servers: Array(source["servers"]).filter_map { |server| server["url"] },
        schemas: @schemas,
        operations: parse_operations(source["paths"] || {}),
        security_schemes: parse_security_schemes(source.dig("components", "securitySchemes") || {}),
        default_security: parse_security_requirements(source["security"])
      )
    end

    private

    def load_source
      contents = File.read(@path)
      document = if File.extname(@path).downcase == ".json"
                   JSON.parse(contents)
                 else
                   Psych.safe_load(contents, aliases: true)
                 end
      return document if document.is_a?(Hash)

      raise StandardError, "OpenAPI document must contain an object"
    end

    def normalize_source(source)
      return Swagger2Converter.convert(source) if source["swagger"].to_s.start_with?("2.")

      source
    end

    def validate_version!(source)
      version = source["openapi"]
      return if version.to_s.match?(/\A3\./)

      raise StandardError, "Only OpenAPI 2.0 and OpenAPI 3.x documents are supported"
    end

    def component_schema(name)
      return @schemas.fetch(name) if @schemas.key?(name)

      definition = @schema_definitions[name]
      raise StandardError, "Unknown schema component: #{name}" unless definition
      return alias_schema(name) if @resolving.include?(name)

      @resolving.add(name)
      begin
        @schemas[name] = parse_schema(definition, name: name)
      ensure
        @resolving.delete(name)
      end
    end

    def parse_operations(paths)
      paths.flat_map do |path, path_item|
        path_parameters = Array(path_item["parameters"])
        HTTP_METHODS.filter_map do |http_method|
          definition = path_item[http_method]
          next unless definition

          parse_operation(path, http_method, definition, path_parameters)
        end
      end
    end

    def parse_operation(path, http_method, definition, path_parameters)
      operation_id = definition["operationId"]
      responses = definition["responses"] || {}
      success_status, success_definition = success_response_entry(responses)

      IR::Operation.new(
        operation_id: operation_id,
        method_name: Naming.operation_method_name(operation_id),
        http_method: http_method,
        path: path,
        summary: definition["summary"],
        parameters: parse_parameters(merge_parameters(path_parameters, Array(definition["parameters"]))),
        request_body: parse_request_body(definition["requestBody"], operation_id),
        success_response: parse_response(success_status, success_definition, operation_id, success: true),
        error_responses: responses.filter_map do |status, response_definition|
          next if success_status.to_s == status.to_s || success_status_code?(status)

          parse_response(status, response_definition, operation_id, success: false)
        end,
        tags: Array(definition["tags"])
      )
    end

    def merge_parameters(path_parameters, operation_parameters)
      (path_parameters + operation_parameters).to_h do |definition|
        [[definition["name"], definition["in"]], definition]
      end.values
    end

    def parse_parameters(definitions)
      definitions.map do |definition|
        wire_name = definition.fetch("name")
        IR::Parameter.new(
          name: Naming.parameter_kwarg_name(wire_name),
          wire_name: wire_name,
          location: definition.fetch("in").to_sym,
          required: definition["required"] == true,
          schema: parse_schema(definition["schema"] || {}),
          description: definition["description"]
        )
      end
    end

    def parse_request_body(definition, operation_id)
      return unless definition

      content = definition["content"] || {}
      wire_content_type = REQUEST_CONTENT_TYPE_KEYS.find { |candidate| content.key?(candidate) }
      if content.any? && wire_content_type.nil?
        raise StandardError, "Unsupported request body content type: #{content.keys.first}"
      end

      content_type = wire_content_type && normalize_request_content_type(wire_content_type)
      media_type = wire_content_type && content.fetch(wire_content_type)
      IR::RequestBody.new(
        required: definition["required"] == true,
        content_type: content_type,
        schema: parse_media_schema(media_type, "#{Naming.schema_class_name(operation_id)}Request"),
        encoding: media_type && media_type["encoding"]
      )
    end

    def normalize_request_content_type(wire_content_type)
      wire_content_type == "text/json" ? "application/json" : wire_content_type
    end

    def success_response_entry(responses)
      return ["200", responses["200"]] if responses.key?("200")
      return [200, responses[200]] if responses.key?(200)

      responses.find { |status, _definition| success_status_code?(status) }
    end

    def success_status_code?(status)
      status.to_s.match?(/\A2\d\d\z/)
    end

    def parse_response(status, definition, operation_id, success:)
      return unless definition

      content = definition["content"] || {}
      content_type = content.key?("application/json") ? "application/json" : content.keys.first
      media_type = content_type && content.fetch(content_type)
      suffix = success ? "Response" : "Response#{status}"

      IR::Response.new(
        status: response_status(status),
        content_type: content_type,
        schema: parse_media_schema(media_type, "#{Naming.schema_class_name(operation_id)}#{suffix}"),
        description: definition["description"]
      )
    end

    def response_status(status)
      status.to_s == "default" ? :default : status.to_i
    end

    def parse_media_schema(media_type, synthetic_name)
      return unless media_type && media_type["schema"]

      definition = media_type.fetch("schema")
      return parse_schema(definition) unless anonymous_named_schema?(definition)
      return @schemas.fetch(synthetic_name) if @schemas.key?(synthetic_name)

      @schemas[synthetic_name] = parse_schema(definition, name: synthetic_name)
    end

    def anonymous_named_schema?(definition)
      !definition.key?("$ref") &&
        (definition["type"] == "object" || definition.key?("properties") || definition["enum"].is_a?(Array))
    end

    def parse_security_schemes(definitions)
      definitions.to_h do |name, definition|
        [name, IR::SecurityScheme.new(
          name: name,
          type: security_scheme_type(definition["type"]),
          api_key_name: definition["name"],
          location: definition["in"]&.to_sym,
          description: definition["description"]
        )]
      end
    end

    def security_scheme_type(type)
      {
        "apiKey" => :api_key,
        "http" => :http,
        "oauth2" => :oauth2,
        "openIdConnect" => :open_id
      }.fetch(type) { type&.to_sym }
    end

    def parse_security_requirements(requirements)
      Array(requirements).map(&:keys)
    end

    def parse_schema(definition, name: nil)
      definition ||= {}
      return referenced_schema(definition.fetch("$ref")) if definition.key?("$ref")
      return composed_object(definition, name) if definition.key?("allOf")
      return union_schema(definition, name) if definition.key?("oneOf") || definition.key?("anyOf")
      return enum_schema(definition, name) if definition["type"] == "string" && definition["enum"].is_a?(Array)
      return array_schema(definition, name) if definition["type"] == "array"
      return object_schema(definition, name) if definition["type"] == "object" || definition.key?("properties")

      primitive_schema(definition, name)
    end

    def referenced_schema(reference)
      match = COMPONENT_REF.match(reference.to_s)
      raise StandardError, "Only in-document schema $ref values are supported: #{reference}" unless match

      component_schema(decode_pointer_token(match[1]))
    end

    def decode_pointer_token(token)
      token.gsub("~1", "/").gsub("~0", "~")
    end

    def object_schema(definition, name)
      required = Array(definition["required"])
      properties = (definition["properties"] || {}).map do |wire_key, property_definition|
        property_schema = parse_schema(property_definition)
        IR::Property.new(
          name: Naming.snake_case(wire_key),
          wire_key: wire_key,
          schema: property_schema,
          required: required.include?(wire_key),
          nullable: property_definition["nullable"] == true || property_schema.nullable == true,
          description: property_definition["description"]
        )
      end

      IR::Schema.new(
        name: name,
        kind: :object,
        properties: properties,
        nullable: definition["nullable"] == true,
        description: definition["description"]
      )
    end

    def enum_schema(definition, name)
      IR::Schema.new(
        name: name,
        kind: :enum,
        ruby_type: name && Naming.schema_class_name(name),
        enum_values: definition["enum"].map(&:to_s),
        nullable: definition["nullable"] == true,
        description: definition["description"]
      )
    end

    def primitive_schema(definition, name)
      ruby_type = PRIMITIVE_TYPES.fetch(definition["type"], "T.untyped")
      IR::Schema.new(
        name: name,
        kind: :primitive,
        ruby_type: ruby_type,
        nullable: definition["nullable"] == true,
        description: definition["description"]
      )
    end

    def array_schema(definition, name)
      items = parse_schema(definition["items"] || {})
      IR::Schema.new(
        name: name,
        kind: :array,
        ruby_type: "T::Array[#{sorbet_type(items)}]",
        items: items,
        nullable: definition["nullable"] == true,
        description: definition["description"]
      )
    end

    def union_schema(definition, name)
      members = definition["oneOf"] || definition["anyOf"]
      parsed_members = members.each_with_index.map do |member, index|
        if member.key?("$ref")
          referenced_schema(member.fetch("$ref"))
        else
          parse_schema(member, name: "#{name || 'Anonymous'}OneOf#{index}")
        end
      end

      IR::Schema.new(
        name: name,
        kind: :union,
        one_of: parsed_members,
        nullable: definition["nullable"] == true,
        description: definition["description"]
      )
    end

    def composed_object(definition, name)
      members = Array(definition["allOf"]).map { |member| parse_schema(member) }
      own_definition = definition.reject { |key, _value| key == "allOf" }
      members << object_schema(own_definition, name) if own_definition.key?("properties")

      properties_by_wire_key = {}
      required_wire_keys = Set.new(Array(definition["required"]))
      members.each do |member|
        Array(member.properties).each do |property|
          properties_by_wire_key[property.wire_key] = property
          required_wire_keys.add(property.wire_key) if property.required
        end
      end
      properties = properties_by_wire_key.values.map do |property|
        property.dup.tap { |copy| copy.required = required_wire_keys.include?(copy.wire_key) }
      end

      IR::Schema.new(
        name: name,
        kind: :object,
        properties: properties,
        nullable: definition["nullable"] == true,
        description: definition["description"]
      )
    end

    def alias_schema(name)
      IR::Schema.new(
        name: name,
        kind: :alias,
        ruby_type: Naming.schema_class_name(name)
      )
    end

    def sorbet_type(schema)
      schema.ruby_type || (schema.name && Naming.schema_class_name(schema.name)) || "T.untyped"
    end
  end
end
