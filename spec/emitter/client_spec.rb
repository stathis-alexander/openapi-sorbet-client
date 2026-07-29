# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe OpenapiSorbetClient::Emitter, "client" do
  def emit_fixture(fixture, output, module_name: "OipTax", gem_name: "oip_tax")
    document = OpenapiSorbetClient::Parser.parse(
      File.expand_path("../fixtures/openapi/#{fixture}", __dir__)
    )

    described_class.new(
      document: document,
      output: output,
      module_name: module_name,
      gem_name: gem_name
    ).emit
  end

  it "emits Faraday client methods with sig, RBS helpers, and typed errors" do
    Dir.mktmpdir do |output|
      emit_fixture("operations.yaml", output)
      root = File.join(output, "oip_tax")
      client = File.read(File.join(root, "lib/oip_tax/client.rb"))
      errors = File.read(File.join(root, "lib/oip_tax/errors.rb"))

      expect(client).to include("require \"faraday\"")
      expect(client).to include("sig do")
      expect(client).to include("def initialize(")
      expect(client).to include("base_url:")
      expect(client).to include("integrator_key:")
      expect(client).to include("subscription_key:")
      expect(client).to include("timeout:")
      expect(client).to include("connection:")
      expect(client).to include("def get_pet(")
      expect(client).to include("def create_pet(")
      expect(client).to include("def get_health")
      expect(client).to include("Models::Pet")
      expect(client).to include("#: (String path_template, Hash[Symbol, String] path_params) -> String")
      expect(client).to include("def interpolate_path(")
      expect(client).to include("#: (Symbol method, String path, ?query: Hash[String, untyped], ?headers: Hash[String, String], ?body: untyped) -> Faraday::Response")
      expect(client).to include("def request(")
      private_section = client.split(/\n\s*private\n/, 2).last
      expect(private_section).to include("def interpolate_path(")
      expect(private_section).to include("def request(")
      expect(private_section).not_to include("sig do")
      expect(private_section).to include("#: (String path_template")

      expect(errors).to include("class Error < StandardError")
      expect(errors).to include("class APIError < Error")
      expect(errors).to include("attr_reader :status")
      expect(errors).to include("attr_reader :body")
      expect(errors).to include("attr_reader :parsed")

      expect(File.read(File.join(root, "sorbet/config"))).to include(
        "--enable-experimental-rbs-comments"
      )
    end
  end

  it "smoke-tests get_pet against Faraday::Adapter::Test" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "operations.yaml",
        output,
        module_name: "ClientSmoke",
        gem_name: "client_smoke"
      )
      root = File.join(output, "client_smoke")
      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "faraday"
      require "client_smoke"

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/pets/abc") do |env|
        expect(env.request_headers["IntegratorKey"]).to eq("ik")
        expect(env.params["subscription-key"]).to eq("sk")
        expect(env.params["$filter"]).to eq("name eq 'Rex'")
        expect(env.request_headers["Authorization"]).to eq("Bearer t")
        [
          200,
          { "Content-Type" => "application/json" },
          JSON.generate("Name" => "Rex")
        ]
      end

      connection = Faraday.new(url: "https://example.com") do |faraday|
        faraday.adapter(:test, stubs)
      end

      client = ClientSmoke::Client.new(
        base_url: "https://example.com",
        integrator_key: "ik",
        subscription_key: "sk",
        connection: connection
      )
      pet = client.get_pet(pet_id: "abc", filter: "name eq 'Rex'", authorization: "Bearer t")

      expect(pet).to be_a(ClientSmoke::Models::Pet)
      expect(pet.name).to eq("Rex")
      stubs.verify_stubbed_calls
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end

  it "raises APIError with status and body on non-2xx" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "operations.yaml",
        output,
        module_name: "ClientErrorSmoke",
        gem_name: "client_error_smoke"
      )
      root = File.join(output, "client_error_smoke")
      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "faraday"
      require "client_error_smoke"

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/pets/missing") do
        [404, { "Content-Type" => "application/json" }, '{"error":"gone"}']
      end

      connection = Faraday.new(url: "https://example.com") do |faraday|
        faraday.adapter(:test, stubs)
      end

      client = ClientErrorSmoke::Client.new(
        base_url: "https://example.com",
        connection: connection
      )

      expect do
        client.get_pet(pet_id: "missing")
      end.to raise_error(ClientErrorSmoke::APIError) { |error|
        expect(error.status).to eq(404)
        expect(error.body).to eq('{"error":"gone"}')
      }
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end

  it "omits HTTP body and Content-Type when optional body kwarg is nil" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "operations.yaml",
        output,
        module_name: "ClientOptionalBody",
        gem_name: "client_optional_body"
      )
      root = File.join(output, "client_optional_body")
      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "faraday"
      require "client_optional_body"

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/optional-pet") do |env|
        expect(env.body).not_to eq("null")
        expect(env.body).to satisfy { |b| b.nil? || b == "" }
        expect(env.request_headers["Content-Type"]).not_to eq("application/json")
        [204, {}, ""]
      end

      connection = Faraday.new(url: "https://example.com") do |faraday|
        faraday.adapter(:test, stubs)
      end
      client = ClientOptionalBody::Client.new(
        base_url: "https://example.com",
        connection: connection
      )

      client.post_optional_pet(body: nil)
      stubs.verify_stubbed_calls
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end

  it "JSON-parses primitive string success and returns raw body for octet-stream" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "operations.yaml",
        output,
        module_name: "ClientPrimitiveSmoke",
        gem_name: "client_primitive_smoke"
      )
      root = File.join(output, "client_primitive_smoke")
      client_src = File.read(File.join(root, "lib/client_primitive_smoke/client.rb"))
      expect(client_src).to include("handle_response(response, :json)")
      expect(client_src).to include("handle_response(response, :raw)")

      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "faraday"
      require "client_primitive_smoke"

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/ping") do
        [200, { "Content-Type" => "application/json" }, JSON.generate("pong")]
      end
      stubs.get("/file") do
        [200, { "Content-Type" => "application/octet-stream" }, "\x00\x01BIN"]
      end
      stubs.get("/health") do
        [200, {}, "ok"]
      end

      connection = Faraday.new(url: "https://example.com") do |faraday|
        faraday.adapter(:test, stubs)
      end
      client = ClientPrimitiveSmoke::Client.new(
        base_url: "https://example.com",
        connection: connection
      )

      expect(client.get_ping).to eq("pong")
      expect(client.get_file).to eq("\x00\x01BIN")
      expect(client.get_health).to eq("ok")
      stubs.verify_stubbed_calls
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end
end
