# frozen_string_literal: true

module OpenapiSorbetClient
  module IR
    Document = Struct.new(
      :title, :version, :servers, :schemas, :operations, :security_schemes, :default_security,
      keyword_init: true
    )
    # schemas: Hash[String, Schema] keyed by components name
    # operations: Array[Operation]
    # security_schemes: Hash[String, SecurityScheme]
    # default_security: Array[Array[String]]  # OR of AND requirement sets (scheme names)

    Schema = Struct.new(
      :name, :kind, :ruby_type, :properties, :enum_values, :items, :one_of, :nullable, :description,
      keyword_init: true
    )
    # kind: :object | :enum | :array | :primitive | :union | :alias
    # ruby_type: String Sorbet expression for primitives/aliases ("String", "Integer", "Float", "T::Boolean", "T::Array[...]")
    # properties: Array[Property] for objects
    # enum_values: Array[String] for string enums
    # items: Schema for arrays
    # one_of: Array[Schema] for unions

    Property = Struct.new(
      :name, :wire_key, :schema, :required, :nullable, :description,
      keyword_init: true
    )
    # name: snake_case Ruby prop; wire_key: original JSON key

    Parameter = Struct.new(
      :name, :wire_name, :location, :required, :schema, :description,
      keyword_init: true
    )
    # location: :path | :query | :header
    # name: kwarg name (filter); wire_name: "$filter"

    RequestBody = Struct.new(
      :required, :content_type, :schema, :encoding,
      keyword_init: true
    )
    # content_type: "application/json" | "multipart/form-data" | "application/x-www-form-urlencoded"
    # encoding: optional Hash for multipart field metadata

    Response = Struct.new(
      :status, :content_type, :schema, :description,
      keyword_init: true
    )
    # status: Integer or :default; schema nil means String body

    Operation = Struct.new(
      :operation_id, :method_name, :http_method, :path, :summary, :parameters,
      :request_body, :success_response, :error_responses, :tags,
      keyword_init: true
    )
    # http_method: "get" | "post" | ...
    # success_response: first 2xx Response (prefer 200)
    # error_responses: Array[Response]

    SecurityScheme = Struct.new(
      :name, :type, :api_key_name, :location, :description,
      keyword_init: true
    )
    # type: :api_key | :http | :oauth2 | :open_id (v1 implements :api_key primarily)
    # location: :header | :query | :cookie
  end
end
