# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe OpenapiSorbetClient::Parser, "operations" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "parses operation identity, parameters, and responses" do
    document = described_class.parse(fixture("operations.yaml"))
    operation = document.operations.find { |candidate| candidate.operation_id == "get-pet" }

    expect(operation.method_name).to eq("get_pet")
    expect(operation.http_method).to eq("get")
    expect(operation.path).to eq("/pets/{petId}")
    expect(operation.summary).to eq("Fetch a pet")
    expect(operation.tags).to eq(["pets"])

    path_parameter, query_parameter, header_parameter = operation.parameters
    expect(path_parameter.to_h).to include(
      name: "pet_id", wire_name: "petId", location: :path, required: true,
      description: "Pet identifier"
    )
    expect(path_parameter.schema.ruby_type).to eq("String")
    expect(query_parameter.to_h).to include(
      name: "filter", wire_name: "$filter", location: :query, required: false
    )
    expect(header_parameter.to_h).to include(
      name: "authorization", wire_name: "Authorization", location: :header, required: false
    )

    expect(operation.success_response.status).to eq(200)
    expect(operation.success_response.content_type).to eq("application/json")
    expect(operation.success_response.schema.name).to eq("Pet")
    expect(operation.success_response.schema.kind).to eq(:object)
    expect(operation.error_responses.map(&:status)).to eq([400])
  end

  it "parses request bodies and selects the first 2xx response when 200 is absent" do
    operation = described_class.parse(fixture("operations.yaml")).operations
      .find { |candidate| candidate.operation_id == "create-pet" }

    expect(operation.request_body.required).to be(true)
    expect(operation.request_body.content_type).to eq("application/json")
    expect(operation.request_body.schema.name).to eq("Pet")
    expect(operation.success_response.status).to eq(201)
    expect(operation.error_responses.map(&:status)).to eq([:default])
  end

  it "allows a success response without content or a schema" do
    operation = described_class.parse(fixture("operations.yaml")).operations
      .find { |candidate| candidate.operation_id == "get-health" }

    expect(operation.success_response.status).to eq(200)
    expect(operation.success_response.content_type).to be_nil
    expect(operation.success_response.schema).to be_nil
  end

  it "lets operation parameters override matching path-item parameters" do
    Tempfile.create(["parameter-override", ".yaml"]) do |file|
      file.write(<<~YAML)
        openapi: 3.0.3
        info: { title: Override, version: "1" }
        paths:
          /pets:
            parameters:
              - name: limit
                in: query
                required: false
                schema: { type: string }
            get:
              operationId: list-pets
              parameters:
                - name: limit
                  in: query
                  required: true
                  schema: { type: integer }
              responses:
                "200": { description: ok }
      YAML
      file.flush

      parameters = described_class.parse(file.path).operations.fetch(0).parameters

      expect(parameters.length).to eq(1)
      expect(parameters.fetch(0).required).to be(true)
      expect(parameters.fetch(0).schema.ruby_type).to eq("Integer")
    end
  end

  it "parses multipart bodies and registers anonymous object schemas" do
    document = described_class.parse(fixture("multipart.yaml"))
    operation = document.operations.fetch(0)

    expect(operation.request_body.content_type).to eq("multipart/form-data")
    expect(operation.request_body.encoding).to eq(
      "file" => { "contentType" => "application/octet-stream" }
    )
    expect(operation.request_body.schema.name).to eq("UploadDocumentRequest")
    expect(document.schemas.fetch("UploadDocumentRequest")).to equal(operation.request_body.schema)
    expect(operation.success_response.schema.name).to eq("UploadDocumentResponse")
    expect(document.schemas.fetch("UploadDocumentResponse")).to equal(operation.success_response.schema)
  end

  it "accepts text/json request bodies as application/json" do
    Tempfile.create(["text-json-body", ".yaml"]) do |file|
      file.write(<<~YAML)
        openapi: 3.0.3
        info: { title: TextJson, version: "1" }
        components:
          schemas:
            Item:
              type: object
              properties:
                name: { type: string }
        paths:
          /items:
            post:
              operationId: create-item
              requestBody:
                required: true
                content:
                  text/json:
                    schema:
                      $ref: "#/components/schemas/Item"
              responses:
                "201": { description: created }
      YAML
      file.flush

      operation = described_class.parse(file.path).operations.fetch(0)

      expect(operation.request_body.content_type).to eq("application/json")
      expect(operation.request_body.schema.name).to eq("Item")
    end
  end

  it "ignores extra JSON media types when application/json is present" do
    Tempfile.create(["multi-json-body", ".yaml"]) do |file|
      file.write(<<~YAML)
        openapi: 3.0.3
        info: { title: MultiJson, version: "1" }
        components:
          schemas:
            Item:
              type: object
              properties:
                name: { type: string }
        paths:
          /items:
            post:
              operationId: create-item
              requestBody:
                content:
                  application/json:
                    schema:
                      $ref: "#/components/schemas/Item"
                  text/json:
                    schema:
                      $ref: "#/components/schemas/Item"
                  application/*+json:
                    schema:
                      $ref: "#/components/schemas/Item"
              responses:
                "201": { description: created }
      YAML
      file.flush

      operation = described_class.parse(file.path).operations.fetch(0)

      expect(operation.request_body.content_type).to eq("application/json")
      expect(operation.request_body.schema.name).to eq("Item")
    end
  end

  it "rejects unsupported request body content types" do
    Tempfile.create(["unsupported-content", ".yaml"]) do |file|
      file.write(<<~YAML)
        openapi: 3.0.3
        info: { title: Unsupported, version: "1" }
        paths:
          /pets:
            post:
              operationId: create-pet
              requestBody:
                content:
                  text/plain:
                    schema: { type: string }
              responses:
                "204": { description: ok }
      YAML
      file.flush

      expect { described_class.parse(file.path) }
        .to raise_error(StandardError, /Unsupported request body content type: text\/plain/)
    end
  end
end
