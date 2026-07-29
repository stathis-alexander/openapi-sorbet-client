# frozen_string_literal: true

module OpenapiSorbetClient
  module Naming
    module_function

    def snake_case(name)
      name
        .to_s
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("-", "_")
        .downcase
    end

    def operation_method_name(operation_id)
      snake_case(operation_id.to_s.tr("-", "_"))
    end

    def parameter_kwarg_name(name)
      cleaned = name.to_s.sub(/\A\$/, "")
      snake_case(cleaned)
    end

    def schema_class_name(name)
      parts = name.to_s.split(/[^A-Za-z0-9]+/)
      return name.to_s if parts.length == 1 && name.to_s.match?(/\A[A-Z]/)

      parts.map { |p| p[0].upcase + p[1..] }.join
    end

    def model_file_name(schema_name)
      snake_case(schema_class_name(schema_name))
    end
  end
end
