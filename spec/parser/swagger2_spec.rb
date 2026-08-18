# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "faraday"

RSpec.describe "OpenAPI 2 / Swagger support" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "parses swagger 2 definitions, body params, and responses into IR" do
    document = OpenapiSorbetClient::Parser.parse(fixture("swagger2.yaml"))

    expect(document.title).to eq("Legacy Petstore")
    expect(document.servers).to eq(["https://petstore.example.com/v2"])
    expect(document.schemas.keys).to include("Pet", "NewPet")

    pet = document.schemas.fetch("Pet")
    expect(pet.kind).to eq(:object)
    expect(pet.properties.map(&:name)).to include("id", "name")
    expect(pet.properties.find { |p| p.name == "id" }.wire_key).to eq("id")

    get_pet = document.operations.find { |op| op.method_name == "get_pet" }
    expect(get_pet.http_method).to eq("get")
    expect(get_pet.path).to eq("/v2/pets/{petId}")
    expect(get_pet.parameters.map(&:name)).to eq(["pet_id"])
    expect(get_pet.parameters.first.location).to eq(:path)
    expect(get_pet.success_response.schema.name).to eq("Pet")

    create_pet = document.operations.find { |op| op.method_name == "create_pet" }
    expect(create_pet.request_body).not_to be_nil
    expect(create_pet.request_body.content_type).to eq("application/json")
    expect(create_pet.request_body.required).to eq(true)
    expect(create_pet.request_body.schema.name).to eq("NewPet")
    expect(create_pet.parameters).to be_empty

    expect(document.security_schemes.keys).to contain_exactly("api_key")
    scheme = document.security_schemes.fetch("api_key")
    expect(scheme.type).to eq(:api_key)
    expect(scheme.api_key_name).to eq("api_key")
    expect(scheme.location).to eq(:header)
    expect(document.default_security).to eq([["api_key"]])
  end

  it "emits a working Faraday client from a swagger 2 spec" do
    Dir.mktmpdir do |dir|
      document = OpenapiSorbetClient::Parser.parse(fixture("swagger2.yaml"))
      OpenapiSorbetClient::Emitter.new(
        document: document,
        output: dir,
        module_name: "LegacyPets",
        gem_name: "legacy_pets_client"
      ).emit

      $LOAD_PATH.unshift(File.join(dir, "legacy_pets_client", "lib"))
      begin
        require "legacy_pets_client"

        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/v2/pets/42") do |env|
          expect(env.request_headers["api_key"]).to eq("secret")
          [200, { "Content-Type" => "application/json" }, '{"id":42,"name":"Fido"}']
        end
        connection = Faraday.new { |f| f.adapter(:test, stubs) }
        client = LegacyPets::Client.new(
          base_url: "https://petstore.example.com",
          api_key: "secret",
          connection: connection
        )

        pet = client.get_pet(pet_id: "42")
        expect(pet).to be_a(LegacyPets::Models::Pet)
        expect(pet.id).to eq(42)
        expect(pet.name).to eq("Fido")
        stubs.verify_stubbed_calls
      ensure
        $LOAD_PATH.delete(File.join(dir, "legacy_pets_client", "lib"))
        Object.send(:remove_const, :LegacyPets) if defined?(LegacyPets)
      end
    end
  end
end
