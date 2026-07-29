# frozen_string_literal: true

module OpenapiSorbetClient
  module TypeExpr
    module_function

    def for_schema(schema, module_name:)
      expr = core_expr(schema, module_name: module_name)
      schema.nullable ? nilable_once(expr) : expr
    end

    def for_property(property, module_name:)
      expr = core_expr(property.schema, module_name: module_name)
      if !property.required || property.nullable
        nilable_once(expr)
      else
        expr
      end
    end

    def core_expr(schema, module_name:)
      case schema.kind
      when :primitive
        schema.ruby_type
      when :object, :enum
        model_type(schema, module_name: module_name)
      when :array
        "T::Array[#{for_schema(schema.items, module_name: module_name)}]"
      when :union
        members = schema.one_of.map { |member| for_schema(member, module_name: module_name) }
        "T.any(#{members.join(', ')})"
      when :alias
        model_type(schema, module_name: module_name)
      else
        schema.ruby_type || "T.untyped"
      end
    end

    def model_type(schema, module_name:)
      if schema.name.to_s.strip.empty?
        return schema.kind == :object ? "T::Hash[String, T.untyped]" : "T.untyped"
      end

      class_name = Naming.schema_class_name(schema.name)
      "#{module_name}::Models::#{class_name}"
    end

    def nilable_once(expr)
      return expr if expr.start_with?("T.nilable(")

      "T.nilable(#{expr})"
    end
  end
end
