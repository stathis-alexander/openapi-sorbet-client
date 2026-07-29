# openapi-sorbet-client

Generate Faraday + Sorbet Ruby client gems from OpenAPI 2.0 / 3.x specifications (YAML or JSON).

## Requirements

- Ruby ≥ 3.2
- OpenAPI **3.x** or Swagger / OpenAPI **2.0** (2.0 is normalized to 3.x before codegen)

## Usage

```bash
bundle exec openapi-sorbet-client generate \
  --spec path/to/openapi.yaml \
  --output ./generated/my_client \
  --module MyApi \
  --gem-name my_api_client
```

| Flag | Description |
|------|-------------|
| `--spec` | Path to the OpenAPI 2.0 or 3.x document (`.yaml`, `.yml`, or `.json`) |
| `--output` | Directory where the generated gem tree is written |
| `--module` | Ruby module name for the client (e.g. `OipTax`) |
| `--gem-name` | Gem name and require path (e.g. `oip_tax_client`) |
| `--synthesize-from-examples` / `--no-synthesize-from-examples` | If a request/response media type has no `schema`, infer one from `example` / `examples` (default: **on**) |

On success the CLI prints `Generated <gem-name> in <output>`.

## What gets generated

Each run emits a standalone gem with:

- A **Faraday**-based `Client` with one flat method per `operationId` (snake_case)
- **`T::Struct`** / **`T::Enum`** DTOs with snake_case Ruby names and explicit wire-key maps to JSON property names
- Public methods use Sorbet **`sig`** (static + runtime checks at the client boundary)
- Private helpers (encode/decode, path building, struct hydration) use experimental **RBS comments** (`#:` / `#|`) only
- `sorbet/config` includes `--enable-experimental-rbs-comments` so those internal signatures type-check
- Typed errors on non-2xx responses (`status`, raw body, optional parsed error DTO)

Document-level security schemes become default Faraday headers or query params; per-operation headers such as `Authorization` stay optional kwargs on each method. OData-style query params like `$filter` are exposed as string kwargs with the `$` stripped (e.g. `filter:`).

When a JSON media type omits `schema` but includes an `example` (common in some vendor specs), the generator **synthesizes** a `T::Struct` from that example by default so callers still get typed `body:` kwargs and `to_wire` / `from_wire`. Disable with `--no-synthesize-from-examples`.

## Scope: JSON envelope only

The generator models the **HTTP JSON envelope** described in the spec. It does **not** parse or validate XML, XSD, or other payload formats embedded in JSON string fields—those remain plain `String` values for hand-written builders upstream.

XSD codegen and runtime dynamic clients are out of scope. OpenAPI 2 support covers the common subset (definitions, body/formData params, responses, apiKey/basic security); exotic 2.0 features may still need hand fixes.

## Example: CCH Axcess Tax Services (OIP)

Against a local copy of the full OIP Tax Services spec (not committed to this repo):

```bash
bundle exec openapi-sorbet-client generate \
  --spec ~/Downloads/oip-tax-service.yaml \
  --output tmp/oip_tax_client \
  --module OipTax \
  --gem-name oip_tax_client
```

CI and unit tests use a trimmed fixture under `spec/fixtures/openapi/oip_tax_trimmed.yaml` so the suite stays offline and fast.

## Development

```bash
bundle install
bundle exec rspec
```
