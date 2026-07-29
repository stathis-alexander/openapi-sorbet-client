# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe OpenapiSorbetClient::Parser, "schemas" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "parses objects with normalized property names and original wire keys" do
    pet = described_class.parse(fixture("minimal.yaml")).schemas.fetch("Pet")

    expect(pet.kind).to eq(:object)
    expect(pet.properties.map(&:name)).to contain_exactly("id", "name", "tag")

    id = pet.properties.find { |property| property.name == "id" }
    expect(id.wire_key).to eq("id")
    expect(id.required).to be(true)
    expect(id.schema.ruby_type).to eq("Integer")

    tag = pet.properties.find { |property| property.name == "tag" }
    expect(tag.wire_key).to eq("tag")
    expect(tag.required).to be(false)
    expect(tag.nullable).to be(true)
  end

  it "resolves component references in properties" do
    document = described_class.parse(fixture("refs.yaml"))
    tag = document.schemas.fetch("Tag")
    tag_property = document.schemas.fetch("Pet").properties.fetch(0)

    expect(tag.kind).to eq(:object)
    expect(tag_property.name).to eq("tag_name")
    expect(tag_property.wire_key).to eq("tagName")
    expect(tag_property.schema.name).to eq("Tag")
    expect(tag_property.schema.kind).to eq(:object)
  end

  it "breaks recursive component reference cycles" do
    Tempfile.create(["recursive-openapi", ".yaml"]) do |file|
      file.write(<<~YAML)
        openapi: 3.0.3
        info: { title: Recursive, version: "1.0" }
        paths: {}
        components:
          schemas:
            Node:
              type: object
              properties:
                parent: { $ref: "#/components/schemas/Node" }
                child: { $ref: "#/components/schemas/Node" }
      YAML
      file.flush

      node = described_class.parse(file.path).schemas.fetch("Node")

      expect(node.properties.map { |property| property.schema.kind }).to eq([:alias, :alias])
    end
  end

  it "parses string enums and nullable references" do
    document = described_class.parse(fixture("enums_nullable.yaml"))
    status = document.schemas.fetch("Status")
    status_property = document.schemas.fetch("Listing").properties.fetch(0)

    expect(status.kind).to eq(:enum)
    expect(status.enum_values).to contain_exactly("available", "pending")
    expect(status_property.schema.name).to eq("Status")
    expect(status_property.nullable).to be(true)
  end

  it "maps primitive formats and arrays to Sorbet types" do
    schemas = described_class.parse(fixture("enums_nullable.yaml")).schemas

    expect(schemas.fetch("CreatedOn").ruby_type).to eq("String")
    expect(schemas.fetch("EventId").ruby_type).to eq("String")
    expect(schemas.fetch("EventIds").ruby_type).to eq("T::Array[String]")
    expect(schemas.fetch("Count").ruby_type).to eq("Integer")
    expect(schemas.fetch("Ratio").ruby_type).to eq("Float")
    expect(schemas.fetch("Enabled").ruby_type).to eq("T::Boolean")
  end

  it "flattens allOf and builds named oneOf unions" do
    document = described_class.parse(fixture("all_of_one_of.yaml"))
    dog = document.schemas.fetch("Dog")
    pet = document.schemas.fetch("Pet")

    expect(dog.kind).to eq(:object)
    expect(dog.properties.map(&:name)).to contain_exactly("name", "breed")
    expect(dog.properties.select(&:required).map(&:name)).to contain_exactly("name", "breed")
    expect(pet.kind).to eq(:union)
    expect(pet.one_of.map(&:name)).to contain_exactly("Dog", "Cat")
  end

  it "accepts OpenAPI 2.0 via swagger conversion" do
    document = described_class.parse(fixture("swagger2.yaml"))

    expect(document.title).to eq("Legacy Petstore")
    expect(document.schemas).to have_key("Pet")
  end
end
