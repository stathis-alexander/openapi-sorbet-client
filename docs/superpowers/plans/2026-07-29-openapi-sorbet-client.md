# OpenAPI → Faraday/Sorbet Client Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Ruby CLI gem that reads OpenAPI 3.x (YAML/JSON) and emits a Faraday + Sorbet client gem with `sig` on the public boundary, RBS comments on internals, and `T::Struct`/`T::Enum` DTOs with snake_case ↔ wire-key mapping.

**Architecture:** Parse OpenAPI into an intermediate representation (IR), then render ERB templates into a complete generated gem. The generator never contacts remote APIs; fixtures and golden files drive tests offline.

**Tech Stack:** Ruby ≥ 3.2, RSpec, ERB, Psych (YAML), Faraday + sorbet-runtime in generated gems, Thor (or OptionParser) for CLI.

## Global Constraints

- OpenAPI **3.x only** (reject 2.0 / Swagger with a clear error).
- Generator models the **JSON envelope only**; XML-carrying string fields stay `String`.
- Public generated API uses Sorbet **`sig`** (static + runtime); private/internal methods use experimental **`#:` / `#|` RBS comments** only.
- Generated `sorbet/config` must include `--enable-experimental-rbs-comments`.
- Property names are **snake_case** Ruby with an explicit **wire-key map** to OpenAPI/JSON names (e.g. `return_id` ↔ `"ReturnID"`).
- `additionalProperties: false` does **not** reject unknown keys at hydrate time; ignore extras.
- OData-style params (`$filter`, `$orderby`) are raw **string kwargs** after stripping leading `$` (`filter:`, `orderby:`).
- Operations are **flat methods on `Client`** named from `operationId` (`get-returns` → `get_returns`).
- Non-2xx responses raise a typed error with `status`, raw `body`, and optional parsed error DTO.
- Tests must pass **without network access** to CCH.
- Motivating consumer fixture source (local, not committed full): `~/Downloads/oip-tax-service.yaml`. Commit only a **trimmed** fixture under `spec/fixtures/openapi/`.
- Branch names must start with `ajs/` if creating new branches.

---

## File Structure

```
openapi-sorbet-client/
  .tool-versions                          # ruby 3.4.8 (or project Ruby)
  Gemfile
  openapi_sorbet_client.gemspec
  Rakefile
  README.md
  exe/openapi-sorbet-client
  lib/openapi_sorbet_client.rb
  lib/openapi_sorbet_client/
    version.rb
    naming.rb                             # snake_case, operation method names, class names
    type_expr.rb                          # IR type → Sorbet type string helpers
    parser.rb                             # OpenAPI → IR::Document
    emitter.rb                            # IR::Document → files on disk
    cli.rb
    ir/
      document.rb
      schema.rb
      property.rb
      operation.rb
      parameter.rb
      request_body.rb
      response.rb
      security_scheme.rb
    templates/
      gemspec.erb
      gemfile.erb
      lib_entry.erb
      version.erb
      errors.erb
      client.erb
      model_struct.erb
      model_enum.erb
      sorbet_config.erb
  spec/
    spec_helper.rb
    naming_spec.rb
    type_expr_spec.rb
    parser/
      load_spec.rb
      schemas_spec.rb
      operations_spec.rb
      security_spec.rb
    emitter/
      models_spec.rb
      client_spec.rb
      golden_spec.rb
    integration/
      oip_tax_trimmed_spec.rb
    fixtures/openapi/
      minimal.yaml
      refs.yaml
      enums_nullable.yaml
      all_of_one_of.yaml
      multipart.yaml
      oip_tax_trimmed.yaml
    golden/
      minimal/
        client_snippet.rb
        pet_model_snippet.rb
```

---

### Task 1: Generator gem scaffolding

**Files:**
- Create: `.tool-versions`, `Gemfile`, `openapi_sorbet_client.gemspec`, `Rakefile`, `README.md`, `exe/openapi-sorbet-client`, `lib/openapi_sorbet_client.rb`, `lib/openapi_sorbet_client/version.rb`, `spec/spec_helper.rb`
- Modify: `.gitignore` (ensure `tmp/`, `generated/`, `.bundle/`, `vendor/bundle/` remain ignored)

**Interfaces:**
- Produces: gem loadable as `OpenapiSorbetClient::VERSION`; `bundle exec rspec` runs (0 examples ok); exe prints help and exits 0 when invoked with `--help` later (stub ok for now)

- [ ] **Step 1: Write `.tool-versions` and gemspec**

```
ruby 3.4.8
```

```ruby
# openapi_sorbet_client.gemspec
# frozen_string_literal: true

require_relative "lib/openapi_sorbet_client/version"

Gem::Specification.new do |spec|
  spec.name = "openapi_sorbet_client"
  spec.version = OpenapiSorbetClient::VERSION
  spec.authors = ["Alexander Stathis"]
  spec.email = ["astathis@users.noreply.github.com"]
  spec.summary = "Generate Faraday + Sorbet Ruby client gems from OpenAPI 3.x"
  spec.description = spec.summary
  spec.homepage = "https://github.com/astathis/openapi-sorbet-client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject { |f| f.start_with?("spec/") }
  end
  spec.bindir = "exe"
  spec.executables = ["openapi-sorbet-client"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
end
```

```ruby
# lib/openapi_sorbet_client/version.rb
# frozen_string_literal: true

module OpenapiSorbetClient
  VERSION = "0.1.0"
end
```

```ruby
# lib/openapi_sorbet_client.rb
# frozen_string_literal: true

require_relative "openapi_sorbet_client/version"

module OpenapiSorbetClient
end
```

```ruby
# Gemfile
# frozen_string_literal: true

source "https://rubygems.org"

gemspec
```

```ruby
# Rakefile
# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)
task default: :spec
```

```ruby
# exe/openapi-sorbet-client
#!/usr/bin/env ruby
# frozen_string_literal: true

require "openapi_sorbet_client"
puts "openapi-sorbet-client #{OpenapiSorbetClient::VERSION}"
```

```ruby
# spec/spec_helper.rb
# frozen_string_literal: true

require "openapi_sorbet_client"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.filter_run_when_matching :focus
  config.order = :random
end
```

```markdown
# openapi-sorbet-client

Generate Faraday + Sorbet Ruby client gems from OpenAPI 3.x specifications.

```bash
bundle exec openapi-sorbet-client generate \
  --spec path/to/openapi.yaml \
  --output ./generated/oip_tax \
  --module OipTax \
  --gem-name oip_tax_client
```
```

- [ ] **Step 2: Make exe executable and install deps**

Run:
```bash
chmod +x exe/openapi-sorbet-client
bundle install
bundle exec ruby -e 'require "openapi_sorbet_client"; puts OpenapiSorbetClient::VERSION'
```
Expected: prints `0.1.0`

- [ ] **Step 3: Commit**

```bash
git add .tool-versions Gemfile openapi_sorbet_client.gemspec Rakefile README.md exe lib spec/spec_helper.rb Gemfile.lock
git commit -m "$(cat <<'EOF'
Scaffold openapi_sorbet_client generator gem.

EOF
)"
```

---

### Task 2: Naming helpers

**Files:**
- Create: `lib/openapi_sorbet_client/naming.rb`, `spec/naming_spec.rb`
- Modify: `lib/openapi_sorbet_client.rb` (require naming)

**Interfaces:**
- Produces:
  - `OpenapiSorbetClient::Naming.snake_case(String) -> String`
  - `OpenapiSorbetClient::Naming.operation_method_name(String) -> String`  # `get-returns` → `get_returns`
  - `OpenapiSorbetClient::Naming.schema_class_name(String) -> String`       # `TaxReturnInfo` → `TaxReturnInfo` (PascalCase preserved / normalized)
  - `OpenapiSorbetClient::Naming.parameter_kwarg_name(String) -> String`   # `$filter` → `filter`, `Content-Type` → `content_type`
  - `OpenapiSorbetClient::Naming.model_file_name(String) -> String`        # `TaxReturnInfo` → `tax_return_info`

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/naming_spec.rb
# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenapiSorbetClient::Naming do
  describe ".snake_case" do
    it "converts PascalCase" do
      expect(described_class.snake_case("ReturnID")).to eq("return_id")
    end

    it "converts camelCase" do
      expect(described_class.snake_case("returnId")).to eq("return_id")
    end

    it "leaves snake_case alone" do
      expect(described_class.snake_case("return_id")).to eq("return_id")
    end

    it "handles acronyms adjacent to words" do
      expect(described_class.snake_case("XMLHttpRequest")).to eq("xml_http_request")
    end
  end

  describe ".operation_method_name" do
    it "maps kebab operationId to snake_case method" do
      expect(described_class.operation_method_name("get-returns")).to eq("get_returns")
    end
  end

  describe ".parameter_kwarg_name" do
    it "strips leading dollar for OData params" do
      expect(described_class.parameter_kwarg_name("$filter")).to eq("filter")
      expect(described_class.parameter_kwarg_name("$orderby")).to eq("orderby")
    end

    it "snake_cases header names" do
      expect(described_class.parameter_kwarg_name("Authorization")).to eq("authorization")
    end
  end

  describe ".schema_class_name" do
    it "keeps PascalCase schema names" do
      expect(described_class.schema_class_name("TaxReturnInfo")).to eq("TaxReturnInfo")
    end

    it "PascalCases snake names" do
      expect(described_class.schema_class_name("tax_return_info")).to eq("TaxReturnInfo")
    end
  end

  describe ".model_file_name" do
    it "snake_cases the class name" do
      expect(described_class.model_file_name("TaxReturnInfo")).to eq("tax_return_info")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/naming_spec.rb -v`
Expected: FAIL (uninitialized constant `OpenapiSorbetClient::Naming` or similar)

- [ ] **Step 3: Implement naming**

```ruby
# lib/openapi_sorbet_client/naming.rb
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
```

Require it from `lib/openapi_sorbet_client.rb`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/naming_spec.rb -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/openapi_sorbet_client/naming.rb lib/openapi_sorbet_client.rb spec/naming_spec.rb
git commit -m "$(cat <<'EOF'
Add naming helpers for snake_case, operations, and kwargs.

EOF
)"
```

---

### Task 3: IR types

**Files:**
- Create: `lib/openapi_sorbet_client/ir/*.rb`, `lib/openapi_sorbet_client/ir.rb`
- Modify: `lib/openapi_sorbet_client.rb`

**Interfaces:**
- Produces frozen/value-ish structs (plain Ruby classes with `attr_reader` + `initialize`) used by parser and emitter:

```ruby
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
```

- [ ] **Step 1: Write a small smoke test**

```ruby
# spec/ir_spec.rb
# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenapiSorbetClient::IR do
  it "builds a document with keyword init" do
    doc = described_class::Document.new(
      title: "Demo",
      version: "1.0",
      servers: ["https://example.com"],
      schemas: {},
      operations: [],
      security_schemes: {},
      default_security: []
    )
    expect(doc.title).to eq("Demo")
  end
end
```

- [ ] **Step 2: Run to verify fail, then implement `lib/openapi_sorbet_client/ir.rb` requiring all IR files (or single file with the Structs above), require from entrypoint, re-run until PASS**

- [ ] **Step 3: Commit**

```bash
git add lib/openapi_sorbet_client/ir.rb lib/openapi_sorbet_client/ir spec/ir_spec.rb lib/openapi_sorbet_client.rb
git commit -m "$(cat <<'EOF'
Define intermediate representation types for OpenAPI documents.

EOF
)"
```

---

### Task 4: Parser — load, version gate, `$ref` resolution, schemas

**Files:**
- Create: `lib/openapi_sorbet_client/parser.rb`, `spec/parser/load_spec.rb`, `spec/parser/schemas_spec.rb`, `spec/fixtures/openapi/minimal.yaml`, `spec/fixtures/openapi/refs.yaml`, `spec/fixtures/openapi/enums_nullable.yaml`, `spec/fixtures/openapi/all_of_one_of.yaml`
- Modify: `lib/openapi_sorbet_client.rb`

**Interfaces:**
- Consumes: OpenAPI file path
- Produces: `OpenapiSorbetClient::Parser.parse(path) -> IR::Document` (operations may be empty until Task 5; schemas populated)

Parser responsibilities this task:
1. Load YAML or JSON via Psych / `JSON.parse`
2. Reject if `openapi` missing or starts with `2.`
3. Resolve in-document `#/components/schemas/...` `$ref`s (cycle-safe)
4. Build `IR::Schema` for objects, string enums (`T::Enum`), primitives (`string`/`integer`/`number`/`boolean`), arrays, `nullable`, `format: date|date-time|uuid` → still `String` (or `Integer` for int), `allOf` flatten (merge properties; required = union), `oneOf` → `kind: :union`

Fixture `minimal.yaml` (keep tiny):

```yaml
openapi: 3.0.3
info:
  title: Minimal Pet
  version: "0.1.0"
servers:
  - url: https://example.com/v1
paths: {}
components:
  schemas:
    Pet:
      type: object
      required: [id, name]
      properties:
        id:
          type: integer
        name:
          type: string
        tag:
          type: string
          nullable: true
```

Fixture `refs.yaml`: Pet `$ref`s Tag; Tag is object with `name: string`.

Fixture `enums_nullable.yaml`: `Status` string enum `available|pending`; object using it.

Fixture `all_of_one_of.yaml`: `Dog` allOf base Animal + breed; `Pet` oneOf Dog|Cat.

- [ ] **Step 1: Write failing parser tests**

```ruby
# spec/parser/schemas_spec.rb
# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenapiSorbetClient::Parser, "schemas" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "parses object schemas with snake_case properties and wire keys" do
    doc = described_class.parse(fixture("minimal.yaml"))
    pet = doc.schemas.fetch("Pet")
    expect(pet.kind).to eq(:object)
    names = pet.properties.map(&:name)
    expect(names).to include("id", "name", "tag")
    id = pet.properties.find { |p| p.name == "id" }
    expect(id.wire_key).to eq("id")
    expect(id.required).to eq(true)
    tag = pet.properties.find { |p| p.name == "tag" }
    expect(tag.nullable).to eq(true)
  end

  it "resolves $ref schemas" do
    doc = described_class.parse(fixture("refs.yaml"))
    expect(doc.schemas).to have_key("Pet")
    expect(doc.schemas).to have_key("Tag")
  end

  it "parses string enums" do
    doc = described_class.parse(fixture("enums_nullable.yaml"))
    status = doc.schemas.fetch("Status")
    expect(status.kind).to eq(:enum)
    expect(status.enum_values).to contain_exactly("available", "pending")
  end

  it "flattens allOf and builds unions for oneOf" do
    doc = described_class.parse(fixture("all_of_one_of.yaml"))
    dog = doc.schemas.fetch("Dog")
    expect(dog.kind).to eq(:object)
    expect(dog.properties.map(&:name)).to include("name", "breed")
    pet = doc.schemas.fetch("Pet")
    expect(pet.kind).to eq(:union)
    expect(pet.one_of.map(&:name)).to include("Dog", "Cat")
  end

  it "rejects OpenAPI 2.0" do
    path = fixture("swagger2.yaml") # create with swagger: "2.0"
    expect { described_class.parse(path) }.to raise_error(/OpenAPI 3/i)
  end
end
```

Also add `spec/parser/load_spec.rb` asserting title/version/servers from `minimal.yaml`.

- [ ] **Step 2: Run tests — expect FAIL**

Run: `bundle exec rspec spec/parser -v`

- [ ] **Step 3: Implement `Parser`**

Key algorithm notes:
- Deep-dup while resolving refs; track `Set` of `#/components/schemas/X` currently resolving to break cycles (emit alias/object stub if needed).
- For object properties: `name = Naming.snake_case(wire_key)`, store both.
- `nullable: true` on property or schema → property.nullable and/or wrap type later as `T.nilable`.
- `allOf`: merge properties left-to-right; later props override same wire_key; required = union of required arrays.
- `oneOf`/`anyOf`: prefer named component refs as union members; inline objects get synthetic names `ParentOneOf0`.
- Primitives map: string→`String`, integer→`Integer`, number→`Float`, boolean→`T::Boolean`.

Keep `operations: []`, `security_schemes: {}` for now if easier — or parse empty paths.

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/openapi_sorbet_client/parser.rb spec/parser spec/fixtures/openapi lib/openapi_sorbet_client.rb
git commit -m "$(cat <<'EOF'
Parse OpenAPI 3 schemas into IR with refs, enums, allOf, and oneOf.

EOF
)"
```

---

### Task 5: Parser — operations, parameters, request/response bodies, security

**Files:**
- Create: `spec/parser/operations_spec.rb`, `spec/parser/security_spec.rb`, `spec/fixtures/openapi/multipart.yaml`
- Modify: `lib/openapi_sorbet_client/parser.rb`, extend `minimal.yaml` (or new `operations.yaml`) with one GET and one POST

**Interfaces:**
- Extends `Parser.parse` so `document.operations` and `document.security_schemes` / `default_security` are populated

Operation fixture sketch (add path to a dedicated fixture `operations.yaml`):

```yaml
openapi: 3.0.3
info: { title: Ops, version: "1" }
servers: [{ url: https://example.com }]
paths:
  /pets/{petId}:
    get:
      operationId: get-pet
      parameters:
        - name: petId
          in: path
          required: true
          schema: { type: string }
        - name: $filter
          in: query
          schema: { type: string }
        - name: Authorization
          in: header
          schema: { type: string }
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Pet"
        "400":
          description: bad
    post:
      operationId: create-pet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/Pet"
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Pet"
components:
  schemas:
    Pet:
      type: object
      properties:
        Name: { type: string }
  securitySchemes:
    apiKeyHeader:
      type: apiKey
      name: IntegratorKey
      in: header
    apiKeyQuery:
      type: apiKey
      name: subscription-key
      in: query
security:
  - apiKeyHeader: []
  - apiKeyQuery: []
```

- [ ] **Step 1: Write failing tests**

```ruby
# assertions:
# - get_pet method_name, http_method get, path "/pets/{petId}"
# - path param pet_id / wire petId required
# - query param filter / wire $filter
# - header authorization
# - success_response schema kind object / name Pet
# - create_pet has request_body content_type application/json
# - security schemes IntegratorKey header + subscription-key query
# - default_security is [["apiKeyHeader"], ["apiKeyQuery"]]
# - missing success content schema → success_response.schema.nil?
# - multipart fixture → request_body.content_type multipart/form-data
```

- [ ] **Step 2: Implement operation + security parsing in `Parser`**

Notes:
- Prefer response status `200`, else first `2xx`.
- Path template keep OpenAPI form (`/pets/{petId}`); emitter interpolates.
- Inline response/request schemas: register under synthetic names if object/enum.
- Unsupported content types: skip with warning string collected on Document optional `warnings` array, or raise — prefer raise for unknown request body content types not in the supported set.

- [ ] **Step 3: Tests PASS, then commit**

```bash
git commit -m "$(cat <<'EOF'
Parse operations, parameters, bodies, and security schemes into IR.

EOF
)"
```

---

### Task 6: Type expression helpers

**Files:**
- Create: `lib/openapi_sorbet_client/type_expr.rb`, `spec/type_expr_spec.rb`

**Interfaces:**
- Produces:
  - `OpenapiSorbetClient::TypeExpr.for_schema(schema, module_name:) -> String`  
    Examples: `"String"`, `"Integer"`, `"T.nilable(String)"`, `"T::Array[String]"`, `"#{module_name}::Models::Pet"`, `"T.any(#{module_name}::Models::Dog, #{module_name}::Models::Cat)"`
  - `OpenapiSorbetClient::TypeExpr.for_property(property, module_name:) -> String` (applies nilable if `!required || nullable`)

Rules:
- Object/enum schemas → `Module::Models::ClassName`
- Union → `T.any(...)`
- Array → `T::Array[...]`
- Primitive uses `schema.ruby_type`
- Nilable wraps with `T.nilable(...)` once

- [ ] **Step 1: Failing tests for the cases above**
- [ ] **Step 2: Implement and pass**
- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add Sorbet type expression helpers for IR schemas.

EOF
)"
```

---

### Task 7: Emitter — gem skeleton + models (`T::Struct` / `T::Enum` + wire keys)

**Files:**
- Create: `lib/openapi_sorbet_client/emitter.rb`, templates listed in File Structure, `spec/emitter/models_spec.rb`
- Modify: entrypoint requires

**Interfaces:**
- Consumes: `IR::Document`, options `{ output:, module_name:, gem_name: }`
- Produces: directory tree under `output/`:

```
<gem_name>/
  Gemfile
  <gem_name>.gemspec
  lib/<gem_name>.rb
  lib/<gem_name>/version.rb
  lib/<gem_name>/errors.rb          # stub ok; filled Task 8
  lib/<gem_name>/client.rb          # stub class Task 8
  lib/<gem_name>/models/<file>.rb
  sorbet/config
```

**Wire-key contract for each struct model:**

```ruby
# typed: strict
# frozen_string_literal: true

module OipTax
  module Models
    class Pet < T::Struct
      const :name, String

      WIRE_KEY_MAP = T.let(
        {
          name: "Name",
        }.freeze,
        T::Hash[Symbol, String]
      )

      sig { params(payload: T::Hash[String, T.untyped]).returns(Pet) }
      def self.from_wire(payload)
        kwargs = {}
        WIRE_KEY_MAP.each do |ruby_key, wire_key|
          next unless payload.key?(wire_key)
          kwargs[ruby_key] = payload[wire_key]
        end
        new(**kwargs)
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_wire
        result = {}
        WIRE_KEY_MAP.each do |ruby_key, wire_key|
          value = public_send(ruby_key)
          next if value.nil? && !self.class.props.fetch(ruby_key).fully_optional?
          result[wire_key] = value.is_a?(T::Struct) ? value.to_wire : value
          # arrays of structs map similarly
        end
        result
      end
    end
  end
end
```

Implement nested struct/array conversion carefully in generated helpers (or a small shared `Models::WireConvertible` module generated once). Prefer a generated `lib/<gem>/models/wire_helpers.rb` included by structs to avoid huge duplication:

```ruby
module WireHelpers
  extend T::Helpers
  # from_wire / to_wire using WIRE_KEY_MAP + prop types
end
```

Enums:

```ruby
class Status < T::Enum
  enums do
    Available = new("available")
    Pending = new("pending")
  end
end
```

`sorbet/config`:

```
--dir
.
--enable-experimental-rbs-comments
```

- [ ] **Step 1: Write failing emitter model tests**

Generate into `Dir.mktmpdir`, parse `minimal.yaml` / PascalCase property fixture, assert:
- model file exists
- content includes `class Pet < T::Struct`
- content includes `WIRE_KEY_MAP` and `"Name"` if fixture uses `Name`
- `sorbet/config` includes `--enable-experimental-rbs-comments`
- gemspec / Gemfile exist

- [ ] **Step 2: Implement Emitter#emit for skeleton + models only (client stub)**
- [ ] **Step 3: PASS + commit**

```bash
git commit -m "$(cat <<'EOF'
Emit generated gem skeleton and T::Struct/T::Enum models with wire keys.

EOF
)"
```

---

### Task 8: Emitter — Faraday `Client`, errors, request helpers (RBS comments)

**Files:**
- Create/modify: `lib/openapi_sorbet_client/templates/client.erb`, `errors.erb`, `spec/emitter/client_spec.rb`
- Modify: `emitter.rb`

**Interfaces:**
- Generated public API:

```ruby
sig do
  params(
    base_url: String,
    integrator_key: T.nilable(String),
    subscription_key: T.nilable(String),
    timeout: T.nilable(Numeric),
    connection: T.nilable(Faraday::Connection)
  ).void
end
def initialize(base_url:, integrator_key: nil, subscription_key: nil, timeout: nil, connection: nil)
```

Map apiKey schemes generically: for each `SecurityScheme` of type api_key, accept a snake_case kwarg (`integrator_key`, `subscription_key`) and apply as Faraday default header or query.

Per operation (example):

```ruby
sig do
  params(
    pet_id: String,
    filter: T.nilable(String),
    authorization: T.nilable(String),
    security: T.nilable(String)
  ).returns(Models::Pet)
end
def get_pet(pet_id:, filter: nil, authorization: nil, security: nil)
  # implementation uses private helpers with RBS comments
end
```

Internal helpers (RBS only, no `sig`):

```ruby
#: (String path_template, Hash[Symbol, String] path_params) -> String
def interpolate_path(path_template, path_params)
  ...
end

#: (Symbol method, String path, ?query: Hash[String, untyped], ?headers: Hash[String, String], ?body: untyped) -> Faraday::Response
def request(method, path, query: {}, headers: {}, body: nil)
  ...
end
```

Errors:

```ruby
class Error < StandardError
  const-like readers: status, body, parsed
end
class APIError < Error; end
```

On non-2xx: raise `APIError` with status/body; if error response has schema, attempt `from_wire`.

JSON body: `body.to_wire` for structs; `JSON.parse` + `from_wire` for success.

Binary / nil schema success → return `response.body` as `String`.

Multipart / form-urlencoded: Faraday multipart / urlencoded encoding based on content_type (minimal working path).

- [ ] **Step 1: Failing tests asserting generated client source contains `sig`, method names, Faraday, RBS comment helpers, error class**
- [ ] **Step 2: Implement templates + emitter wiring**
- [ ] **Step 3: Optional load-and-smoke: generate to tmpdir, add generated gem to `$LOAD_PATH`, stub Faraday with `Faraday::Adapter::Test`, call `get_pet`, expect struct**
- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Emit Faraday client methods with sig boundary and RBS internals.

EOF
)"
```

---

### Task 9: CLI `generate` command

**Files:**
- Create/replace: `lib/openapi_sorbet_client/cli.rb`, update `exe/openapi-sorbet-client`
- Create: `spec/cli_spec.rb`

**Interfaces:**

```bash
openapi-sorbet-client generate \
  --spec PATH \
  --output DIR \
  --module ModuleName \
  --gem-name gem_name
```

Thor class:

```ruby
module OpenapiSorbetClient
  class CLI < Thor
    desc "generate", "Generate a Faraday/Sorbet client gem from an OpenAPI 3 spec"
    method_option :spec, type: :string, required: true
    method_option :output, type: :string, required: true
    method_option :module, type: :string, required: true
    method_option :"gem-name", type: :string, required: true
    def generate
      document = Parser.parse(options[:spec])
      Emitter.new(
        document: document,
        output: options[:output],
        module_name: options[:module],
        gem_name: options[:"gem-name"]
      ).emit
      say "Generated #{options[:"gem-name"]} in #{options[:output]}"
    end
  end
end
```

exe:

```ruby
#!/usr/bin/env ruby
require "openapi_sorbet_client"
OpenapiSorbetClient::CLI.start(ARGV)
```

- [ ] **Step 1: CLI spec using tmpdir + minimal fixture**
- [ ] **Step 2: Implement + PASS**
- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add Thor CLI generate command for client emission.

EOF
)"
```

---

### Task 10: Golden-file tests

**Files:**
- Create: `spec/emitter/golden_spec.rb`, `spec/golden/minimal/client_snippet.rb`, `spec/golden/minimal/pet_model_snippet.rb`
- Optionally extend fixtures

**Interfaces:**
- After generating from `minimal.yaml` / `operations.yaml`, assert generated files **include** golden snippets (substring or normalized compare). Prefer include-match on stable fragments to reduce churn.

Example golden `pet_model_snippet.rb`:

```ruby
class Pet < T::Struct
  const :id, Integer
  const :name, String
  const :tag, T.nilable(String)
```

Example golden client fragment:

```ruby
sig do
  params(
    pet_id: String,
    filter: T.nilable(String),
    authorization: T.nilable(String)
  ).returns(Models::Pet)
end
def get_pet(pet_id:, filter: nil, authorization: nil)
```

- [ ] **Step 1: Generate once locally, craft golden snippets from real output**
- [ ] **Step 2: Spec fails if snippets missing; pass when present**
- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add golden-file snippet assertions for generated client and models.

EOF
)"
```

---

### Task 11: Trimmed OIP Tax fixture + integration test

**Files:**
- Create: `spec/fixtures/openapi/oip_tax_trimmed.yaml`, `spec/integration/oip_tax_trimmed_spec.rb`

**Interfaces / fixture contents:**
Manually trim from `~/Downloads/oip-tax-service.yaml` to include:
- `openapi`/`info`/`servers`/`security`/`securitySchemes` (IntegratorKey + subscription-key)
- Paths: `GET /api/v1/Returns` (`get-returns`) and `POST /api/v1/CalculateReturn` (or `ReturnsImportBatch`) with their parameters/bodies
- Schemas: `ReturnsResponse`, `TaxReturnInfo`, `CalculateReturnRequest` (includes `ConfigurationXml` string), and any `$ref` targets those need

Keep fixture small (ideally < 400 lines) but real PascalCase keys.

Integration assertions:
1. `Parser.parse` succeeds; finds `get_returns` and calculate/import operation
2. `Emitter` generates gem; `Models::TaxReturnInfo` has `return_id` ↔ `ReturnID`
3. `ConfigurationXml` / `configuration_xml` typed as `String`
4. Faraday test adapter: stub GET Returns JSON → hydrate `ReturnsResponse` / array of returns
5. Stub POST → accepts wire JSON with `ConfigurationXml`

No live CCH calls.

- [ ] **Step 1: Create trimmed YAML fixture**
- [ ] **Step 2: Write integration spec**
- [ ] **Step 3: PASS full suite `bundle exec rspec`**
- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add trimmed OIP Tax fixture and offline integration coverage.

EOF
)"
```

---

### Task 12: README polish + end-to-end smoke on full local OIP spec (optional check)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document CLI flags, Sorbet RBS comment requirement, JSON-envelope-only scope, example against OIP**
- [ ] **Step 2: Manually run (not CI) against `~/Downloads/oip-tax-service.yaml` into `tmp/oip_tax_client` and confirm generate completes; if Sorbet is installed, optionally `srb tc` in generated gem. Do not commit full generated output.
- [ ] **Step 3: Commit README only**

```bash
git commit -m "$(cat <<'EOF'
Document generator usage and JSON-envelope scope.

EOF
)"
```

---

## Self-review (plan vs spec)

| Spec requirement | Task |
|---|---|
| CLI generate with --spec/--output/--module/--gem-name | 9 |
| Faraday client | 8 |
| Public `sig` + runtime boundary | 8 |
| Internal RBS comments + sorbet/config flag | 7–8 |
| T::Struct / T::Enum DTOs | 7 |
| snake_case ↔ wire keys | 2, 4, 7 |
| Document + per-op security / Authorization kwargs | 5, 8 |
| `$filter` as raw string kwarg | 2, 5, 8 |
| OpenAPI 3 YAML/JSON, $ref | 4 |
| path/query/header params | 5 |
| JSON + multipart + form-urlencoded bodies | 5, 8 |
| allOf / oneOf | 4, 6, 7 |
| primitives, arrays, date/uuid as strings | 4, 6 |
| Binary / missing schema → String | 5, 8 |
| Non-2xx typed errors | 8 |
| Unit + golden + trimmed OIP integration offline | 2–6, 10, 11 |
| ConfigurationXml stays String | 11 |
| No OpenAPI 2 / no XSD codegen | 4 (reject), out of scope |

No placeholders left in tasks; IR/type/naming signatures are consistent across tasks (`get_returns`, `WIRE_KEY_MAP`, `from_wire`/`to_wire`, `Parser.parse`, `Emitter#emit`).
