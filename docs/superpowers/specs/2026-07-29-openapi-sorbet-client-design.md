# OpenAPI → Faraday/Sorbet Client Generator

**Date:** 2026-07-29  
**Repo:** `~/code/openapi-sorbet-client`  
**Status:** Approved design (pending implementation plan)

## Goal

Build a Ruby CLI gem that reads an OpenAPI 3.x spec (YAML or JSON) and emits a **generated Ruby client gem** that:

- Uses **Faraday** for HTTP
- Exposes a typed public API with Sorbet **`sig`** (static + runtime checks at the client boundary)
- Uses experimental **RBS comment** signatures (`#:`) for internal/private methods
- Models non-primitive DTOs as **`T::Struct`** (and string enums as **`T::Enum`**)
- Maps idiomatic **snake_case** Ruby properties to wire JSON keys (e.g. PascalCase)

## Motivating consumer

CCH Axcess **Tax Services v2** (`oip-tax-service.yaml`):

- OpenAPI 3.0.1, ~38 operations, ~70 schemas, almost entirely `application/json`
- Dual apiKey security (`IntegratorKey` header, `subscription-key` query) plus per-operation `Authorization` / `Security` headers
- Heavy OData-style `$filter` query parameters
- Error responses often lack schemas
- File download success responses may lack content schemas

**Important layering note:** The HTTP envelope is JSON (as documented). Domain tax payloads are often **XML embedded as JSON strings** (`ConfigurationXml`, base64 `FileDataList`, etc.). This generator models the **JSON envelope only**. XML/XSD payload builders remain out of scope (hand-written, as in Obsidian today). Opaque string fields stay `String`.

## Approach

**Parse → intermediate representation (IR) → ERB templates → generated gem.**

Rejected alternatives:

- Custom openapi-generator templates (hard to control Sorbet/`sig`/RBS/Faraday shape)
- Runtime dynamic client from the spec (weak static typing; not a produced gem)

## Repository layout (generator)

```
openapi-sorbet-client/
  exe/openapi-sorbet-client
  lib/openapi_sorbet_client/
    cli.rb
    parser.rb
    ir/           # Operation, Schema, Parameter, SecurityScheme, ...
    emitter.rb
    templates/    # ERB for gem skeleton + Ruby sources
  spec/
    fixtures/openapi/   # small specs + trimmed oip-tax-service
    golden/             # expected generated snippets
  docs/superpowers/specs/
```

### CLI

```bash
openapi-sorbet-client generate \
  --spec path/to/openapi.yaml \
  --output ./generated/oip_tax \
  --module OipTax \
  --gem-name oip_tax_client
```

## Generated gem shape

```
oip_tax_client/
  Gemfile
  oip_tax_client.gemspec
  lib/oip_tax_client.rb
  lib/oip_tax_client/
    client.rb
    models/*.rb
    errors.rb
    version.rb
  sorbet/config   # includes --enable-experimental-rbs-comments
```

### Public API (runtime `sig`)

- `Client#initialize` configures Faraday (`base_url`, timeouts, default headers/query from security schemes, optional Faraday connection injection for tests).
- One public method per `operationId`, **flat on `Client`** for v1 (optional tag grouping later).
- Kwargs for path/query/header parameters; JSON body as a `T::Struct` (or nil).
- Return type: success DTO struct; `String` when no schema / binary-ish body; arrays/aliases as appropriate.
- Non-2xx → raise typed error carrying `status`, raw `body`, and optional parsed error DTO when a schema exists.

### Internal methods (RBS comments)

Request building, JSON encode/decode, path interpolation, and struct ↔ wire-key mapping use `#:` / `#|` RBS comments only (static checking; no sorbet-runtime cost).

Generated `sorbet/config` must include:

```
--enable-experimental-rbs-comments
```

### DTOs

- One `T::Struct` per object schema in `components/schemas` (and inline object schemas as needed).
- `T::Enum` for string enums.
- snake_case property names with an explicit wire-key map (e.g. `return_id` ↔ `"ReturnID"`).
- `nullable: true` → `T.nilable(...)`.
- XML-carrying string fields remain `String`.
- `additionalProperties: false` does not force strict reject-on-unknown at runtime; unknown keys are ignored when hydrating structs.

### Auth

- Apply document-level `security` / `securitySchemes` as Faraday default headers or query params (e.g. `IntegratorKey`, `subscription-key`).
- Per-operation header parameters such as `Authorization` and `Security` remain optional kwargs on each generated method.

### `$filter` and similar params

v1 exposes OData-style parameters as raw string kwargs (caller builds the filter expression). Sugar helpers are a later enhancement.

## OpenAPI feature support (v1)

**Supported:**

- OpenAPI 3.x YAML and JSON
- OpenAPI 2.0 / Swagger (normalized to OpenAPI 3 shape before IR/codegen)
- In-document `$ref` resolution
- Path, query, and header parameters
- JSON request and response bodies
- Multipart and `application/x-www-form-urlencoded` request bodies
- `allOf` (flatten into a single struct when feasible)
- `oneOf` (`T.any(...)` or a small union helper)
- Primitives, arrays, objects; `format: date`, `date-time`, `uuid`
- Binary / missing success content schema → `String`

**Not supported in v1:**

- Webhooks, callbacks, links
- XSD / XML domain payload codegen
- Publishing generated gems to RubyGems as part of the generator workflow
- Automatic Obsidian integration (consumers can path-depend on a generated gem later)

## Testing strategy

1. **Unit tests** for parser, IR construction, naming (snake_case, operation method names), and `$ref` resolution.
2. **Golden-file tests** with small fixture specs asserting generated Ruby snippets.
3. **Integration:** generate from a trimmed `oip-tax-service` fixture; assert representative operations and models exist; Faraday stub smoke test for one GET and one POST.

## Success criteria

- `generate` against the OIP Tax OpenAPI spec produces a gem that typechecks under Sorbet with experimental RBS comments enabled.
- Public client methods have `sig` and raise at runtime on type mismatches at the boundary.
- `list_returns`-style JSON responses hydrate into snake_case `T::Struct`s with correct wire-key mapping.
- Fields like `ConfigurationXml` are typed as `String` (opaque).
- Generator test suite is green without network access to CCH.
