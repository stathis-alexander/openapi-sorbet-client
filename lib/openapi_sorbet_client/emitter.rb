# frozen_string_literal: true

require "erb"
require "fileutils"
require "set"

module OpenapiSorbetClient
  class Emitter
    TEMPLATE_DIRECTORY = File.expand_path("templates", __dir__)

    def initialize(document:, output:, module_name:, gem_name:)
      @document = document
      @output = output
      @module_name = module_name
      @gem_name = gem_name
    end

    def emit
      FileUtils.mkdir_p(models_directory)
      FileUtils.mkdir_p(File.join(root, "sorbet"))

      render("gemfile", File.join(root, "Gemfile"))
      render("gemspec", File.join(root, "#{gem_name}.gemspec"))
      render("lib_entry", File.join(root, "lib", "#{gem_name}.rb"), schemas: emitted_schemas)
      render("version", File.join(library_directory, "version.rb"))
      render("errors", File.join(library_directory, "errors.rb"))
      render("client", File.join(library_directory, "client.rb"))
      render("wire_helpers", File.join(models_directory, "wire_helpers.rb"))
      render("sorbet_config", File.join(root, "sorbet", "config"))
      emit_models

      root
    end

    private

    attr_reader :document, :output, :module_name, :gem_name

    def root
      @root ||= File.join(output, gem_name)
    end

    def library_directory
      File.join(root, "lib", gem_name)
    end

    def models_directory
      File.join(library_directory, "models")
    end

    def emitted_schemas
      document.schemas.values.select do |schema|
        schema.name && !schema.name.to_s.strip.empty? && %i[object enum].include?(schema.kind)
      end
    end

    # Single models.rb avoids circular require_relative between per-model files.
    # Classes are ordered enums-first, then objects in dependency order. Forward or
    # cyclic model references use T.untyped on const types while WIRE_TYPE_MAP keeps
    # string class names for runtime from_wire deserialization.
    def emit_models
      defined_names = Set.new
      chunks = ordered_emitted_schemas.map do |schema|
        template = schema.kind == :enum ? "model_enum" : "model_struct"
        chunk = render_string(template, schema: schema, defined_names: defined_names)
        defined_names.add(schema.name)
        chunk
      end

      File.write(File.join(library_directory, "models.rb"), chunks.join("\n"))
    end

    def ordered_emitted_schemas
      enums, objects = emitted_schemas.partition { |schema| schema.kind == :enum }
      enums.sort_by(&:name) + topological_objects(objects)
    end

    def topological_objects(objects)
      by_name = objects.to_h { |schema| [schema.name, schema] }
      remaining = by_name.keys.to_set
      ordered = []

      loop do
        progress = remaining.select do |name|
          model_dependencies(by_name.fetch(name)).all? do |dep|
            !remaining.include?(dep)
          end
        end.sort

        break if progress.empty?

        progress.each do |name|
          ordered << by_name.fetch(name)
          remaining.delete(name)
        end
      end

      # Cyclic leftovers: emit alphabetically; property_type uses T.untyped for
      # not-yet-defined model refs.
      ordered.concat(remaining.sort.map { |name| by_name.fetch(name) })
      ordered
    end

    def model_dependencies(schema)
      Array(schema.properties).flat_map { |property| named_model_refs(property.schema) }.uniq
    end

    def named_model_refs(schema)
      return [] if schema.nil?

      case schema.kind
      when :object, :enum, :alias
        name = schema.name.to_s
        name.strip.empty? ? [] : [name]
      when :array
        named_model_refs(schema.items)
      when :union
        Array(schema.one_of).flat_map { |member| named_model_refs(member) }
      else
        []
      end
    end

    def render(template_name, destination, locals = {})
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, render_string(template_name, locals))
    end

    def render_string(template_name, locals = {})
      template = File.read(File.join(TEMPLATE_DIRECTORY, "#{template_name}.erb"))
      ERB.new(template, trim_mode: "-").result_with_hash(
        {
          document: document,
          module_name: module_name,
          gem_name: gem_name,
          emitter: self,
          defined_names: Set.new
        }.merge(locals)
      )
    end

    public

    def property_type(property, defined_names: Set.new)
      expr = core_type(property.schema, defined_names: defined_names)
      if !property.required || property.nullable
        TypeExpr.nilable_once(expr)
      else
        expr
      end
    end

    def core_type(schema, defined_names: Set.new)
      case schema.kind
      when :primitive
        schema.ruby_type
      when :object, :enum, :alias
        if schema.name.to_s.strip.empty?
          schema.kind == :object ? "T::Hash[String, T.untyped]" : "T.untyped"
        elsif defined_names.include?(schema.name)
          TypeExpr.core_expr(schema, module_name: module_name)
        else
          "T.untyped"
        end
      when :array
        "T::Array[#{property_schema_type(schema.items, defined_names: defined_names)}]"
      when :union
        members = schema.one_of.map { |member| property_schema_type(member, defined_names: defined_names) }
        "T.any(#{members.join(', ')})"
      else
        schema.ruby_type || "T.untyped"
      end
    end

    def property_schema_type(schema, defined_names: Set.new)
      expr = core_type(schema, defined_names: defined_names)
      schema.nullable ? TypeExpr.nilable_once(expr) : expr
    end

    def wire_type_descriptor(schema)
      case schema.kind
      when :object, :enum, :alias
        return "nil" if schema.name.to_s.strip.empty?

        %("#{TypeExpr.core_expr(schema, module_name: module_name)}")
      when :array
        "[#{wire_type_descriptor(schema.items)}]"
      else
        "nil"
      end
    end

    def enum_members(schema)
      used_names = Hash.new(0)
      schema.enum_values.map do |value|
        base_name = Naming.schema_class_name(value)
        base_name = "Value#{base_name}" unless base_name.match?(/\A[A-Z]/)
        used_names[base_name] += 1
        suffix = used_names[base_name] == 1 ? "" : used_names[base_name].to_s
        ["#{base_name}#{suffix}", value]
      end
    end

    def api_key_schemes
      document.security_schemes.values.select { |scheme| scheme.type == :api_key }
    end

    def api_key_kwarg(scheme)
      Naming.snake_case(scheme.api_key_name)
    end

    def client_schema_type(schema)
      return "String" if schema.nil?

      TypeExpr.for_schema(schema, module_name: module_name).delete_prefix("#{module_name}::")
    end

    def client_success_type(operation)
      schema = operation.success_response&.schema
      return "String" if schema.nil?

      client_schema_type(schema)
    end

    def raw_success_body?(response)
      return true if response.nil? || response.schema.nil?

      binary_content_type?(response.content_type)
    end

    def binary_content_type?(content_type)
      ct = content_type.to_s.downcase
      return false if ct.empty?

      ct.include?("octet-stream") ||
        ct.start_with?("image/", "audio/", "video/") ||
        ct == "application/pdf"
    end

    def runtime_schema_expr(schema)
      return ":raw" if schema.nil?

      case schema.kind
      when :object, :enum, :alias
        return ":json" if schema.name.to_s.strip.empty?

        client_schema_type(schema)
      when :array
        item_expr = runtime_schema_expr(schema.items)
        item_expr == ":raw" ? ":json" : "[#{item_expr}]"
      when :union
        members = Array(schema.one_of).map { |member| runtime_schema_expr(member) }
        "{ union: [#{members.join(', ')}] }"
      when :primitive
        ":json"
      else
        ":json"
      end
    end

    def success_schema_expr(operation)
      response = operation.success_response
      return ":raw" if raw_success_body?(response)

      runtime_schema_expr(response.schema)
    end

    def render_operation_method(operation)
      params = operation_method_params(operation)
      lines = []
      if params.empty?
        lines << "    sig { returns(#{client_success_type(operation)}) }"
      else
        lines << "    sig do"
        lines << "      params("
        params.each_with_index do |param, index|
          comma = index == params.length - 1 ? "" : ","
          lines << "        #{param[:name]}: #{param[:type]}#{comma}"
        end
        lines << "      ).returns(#{client_success_type(operation)})"
        lines << "    end"
      end

      if params.empty?
        lines << "    def #{operation.method_name}"
      else
        def_args = params.map do |param|
          param[:required] ? "#{param[:name]}:" : "#{param[:name]}: nil"
        end
        lines << "    def #{operation.method_name}(#{def_args.join(', ')})"
      end

      lines.concat(operation_method_body(operation, params).map { |line| "      #{line}" })
      lines << "    end"
      lines << ""

      lines << render_odata_filter_method(operation, params) if operation.odata_filter

      lines.join("\n")
    end

    # Emits a typed sibling method that assembles the operation's raw string $filter param from
    # kwargs, using field names from the overrides file rather than the (possibly wrong) ones in
    # the vendor spec's prose/examples. The underlying string-based method stays available too.
    def render_odata_filter_method(operation, params)
      filter = operation.odata_filter
      other_params = params.reject { |param| param[:name] == filter.param_name }
      filter_fields = filter.fields

      lines = []
      lines << "sig do"
      lines << "  params("
      sig_entries = filter_fields.map do |field|
        type = field.required ? "String" : "T.nilable(String)"
        "#{field.name}: #{type}"
      end
      sig_entries += other_params.map do |param|
        "#{param[:name]}: #{param[:type]}"
      end
      sig_entries.each_with_index do |entry, index|
        comma = index == sig_entries.length - 1 ? "" : ","
        lines << "    #{entry}#{comma}"
      end
      lines << "  ).returns(#{client_success_type(operation)})"
      lines << "end"

      def_args = filter_fields.map do |field|
        field.required ? "#{field.name}:" : "#{field.name}: nil"
      end
      def_args += other_params.map do |param|
        param[:required] ? "#{param[:name]}:" : "#{param[:name]}: nil"
      end
      lines << "def #{operation.method_name}_by_#{filter.param_name}(#{def_args.join(', ')})"

      lines << "  #{filter.param_name}_clauses = ["
      filter_fields.each do |field|
        lines << "    (#{field.name} ? #{field.wire_name.inspect} + \" eq '\" + #{field.name} + \"'\" : nil),"
      end
      lines << "  ].compact"
      lines << "  #{operation.method_name}("
      lines << "    #{filter.param_name}: #{filter.param_name}_clauses.join(\" and \"),"
      other_params.each { |param| lines << "    #{param[:name]}: #{param[:name]}," }
      lines << "  )"
      lines << "end"

      lines.map { |line| "    #{line}" }.join("\n")
    end

    def operation_method_params(operation)
      params = []

      Array(operation.parameters).each do |parameter|
        type = client_schema_type(parameter.schema)
        type = TypeExpr.nilable_once(type) unless parameter.required
        params << {
          name: parameter.name,
          type: type,
          required: parameter.required,
          kind: :parameter,
          parameter: parameter
        }
      end

      if operation.request_body
        body = operation.request_body
        type = client_schema_type(body.schema)
        type = TypeExpr.nilable_once(type) unless body.required
        params << {
          name: "body",
          type: type,
          required: body.required,
          kind: :body
        }
      end

      params
    end

    def operation_method_body(operation, params)
      lines = []
      path_params = Array(operation.parameters).select { |parameter| parameter.location == :path }
      query_params = Array(operation.parameters).select { |parameter| parameter.location == :query }
      header_params = Array(operation.parameters).select { |parameter| parameter.location == :header }

      if path_params.empty?
        lines << "path = #{operation.path.inspect}"
      else
        hash_entries = path_params.map do |parameter|
          "#{parameter.wire_name.to_sym.inspect} => #{parameter.name}"
        end
        lines << "path = interpolate_path(#{operation.path.inspect}, { #{hash_entries.join(', ')} })"
      end

      if query_params.empty?
        lines << "query = {}"
      else
        lines << "query = {"
        query_params.each do |parameter|
          lines << "  #{parameter.wire_name.inspect} => #{parameter.name},"
        end
        lines << "}.compact"
      end

      if header_params.empty?
        lines << "headers = {}"
      else
        lines << "headers = {"
        header_params.each do |parameter|
          lines << "  #{parameter.wire_name.inspect} => #{parameter.name},"
        end
        lines << "}.compact"
      end

      if operation.request_body
        content_type = operation.request_body.content_type || "application/json"
        lines << "encoded_body, body_headers = encode_body(body, #{content_type.inspect})"
        lines << "headers = headers.merge(body_headers)"
        lines << "response = request(#{operation.http_method.to_sym.inspect}, path, query: query, headers: headers, body: encoded_body)"
      else
        lines << "response = request(#{operation.http_method.to_sym.inspect}, path, query: query, headers: headers)"
      end

      success_expr = success_schema_expr(operation)
      error_entries = Array(operation.error_responses).filter_map do |error|
        next if error.schema.nil?

        key = error.status == :default ? ":default" : error.status.inspect
        "#{key} => #{runtime_schema_expr(error.schema)}"
      end

      if error_entries.empty?
        lines << "handle_response(response, #{success_expr})"
      else
        lines << "handle_response("
        lines << "  response,"
        lines << "  #{success_expr},"
        lines << "  {"
        error_entries.each { |entry| lines << "    #{entry}," }
        lines << "  }"
        lines << ")"
      end

      lines
    end
  end
end
