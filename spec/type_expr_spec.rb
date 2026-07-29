# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenapiSorbetClient::TypeExpr do
  let(:module_name) { "OipTax" }

  describe ".for_schema" do
    it "returns ruby_type for primitives" do
      schema = OpenapiSorbetClient::IR::Schema.new(
        kind: :primitive,
        ruby_type: "String"
      )
      expect(described_class.for_schema(schema, module_name: module_name)).to eq("String")
    end

    it "wraps nullable primitives once" do
      schema = OpenapiSorbetClient::IR::Schema.new(
        kind: :primitive,
        ruby_type: "Integer",
        nullable: true
      )
      expect(described_class.for_schema(schema, module_name: module_name)).to eq("T.nilable(Integer)")
    end

    it "returns module model path for objects" do
      schema = OpenapiSorbetClient::IR::Schema.new(
        name: "Pet",
        kind: :object,
        properties: []
      )
      expect(described_class.for_schema(schema, module_name: module_name)).to eq("OipTax::Models::Pet")
    end

    it "falls back for nameless objects instead of emitting a trailing ::" do
      schema = OpenapiSorbetClient::IR::Schema.new(
        kind: :object,
        properties: []
      )
      expect(described_class.for_schema(schema, module_name: module_name)).to eq(
        "T::Hash[String, T.untyped]"
      )
      expect(described_class.for_schema(schema, module_name: module_name)).not_to match(/Models::\z/)
    end

    it "falls back for nameless enums instead of emitting a trailing ::" do
      schema = OpenapiSorbetClient::IR::Schema.new(
        kind: :enum,
        enum_values: %w[a b]
      )
      expect(described_class.for_schema(schema, module_name: module_name)).to eq("T.untyped")
    end

    it "returns module model path for enums" do
      schema = OpenapiSorbetClient::IR::Schema.new(
        name: "pet_status",
        kind: :enum,
        enum_values: %w[available pending]
      )
      expect(described_class.for_schema(schema, module_name: module_name)).to eq("OipTax::Models::PetStatus")
    end

    it "builds array types from items" do
      items = OpenapiSorbetClient::IR::Schema.new(kind: :primitive, ruby_type: "String")
      schema = OpenapiSorbetClient::IR::Schema.new(kind: :array, items: items)
      expect(described_class.for_schema(schema, module_name: module_name)).to eq("T::Array[String]")
    end

    it "builds union types" do
      dog = OpenapiSorbetClient::IR::Schema.new(name: "Dog", kind: :object, properties: [])
      cat = OpenapiSorbetClient::IR::Schema.new(name: "Cat", kind: :object, properties: [])
      schema = OpenapiSorbetClient::IR::Schema.new(kind: :union, one_of: [dog, cat])
      expect(described_class.for_schema(schema, module_name: module_name)).to eq(
        "T.any(OipTax::Models::Dog, OipTax::Models::Cat)"
      )
    end
  end

  describe ".for_property" do
    let(:string_schema) do
      OpenapiSorbetClient::IR::Schema.new(kind: :primitive, ruby_type: "String")
    end

    it "returns the schema type for required non-nullable properties" do
      property = OpenapiSorbetClient::IR::Property.new(
        name: "name",
        wire_key: "name",
        schema: string_schema,
        required: true,
        nullable: false
      )
      expect(described_class.for_property(property, module_name: module_name)).to eq("String")
    end

    it "wraps optional properties" do
      property = OpenapiSorbetClient::IR::Property.new(
        name: "nickname",
        wire_key: "nickname",
        schema: string_schema,
        required: false,
        nullable: false
      )
      expect(described_class.for_property(property, module_name: module_name)).to eq("T.nilable(String)")
    end

    it "wraps nullable properties once" do
      property = OpenapiSorbetClient::IR::Property.new(
        name: "nickname",
        wire_key: "nickname",
        schema: string_schema,
        required: true,
        nullable: true
      )
      expect(described_class.for_property(property, module_name: module_name)).to eq("T.nilable(String)")
    end

    it "does not double-wrap optional nullable properties" do
      nullable_schema = OpenapiSorbetClient::IR::Schema.new(
        kind: :primitive,
        ruby_type: "String",
        nullable: true
      )
      property = OpenapiSorbetClient::IR::Property.new(
        name: "nickname",
        wire_key: "nickname",
        schema: nullable_schema,
        required: false,
        nullable: true
      )
      expect(described_class.for_property(property, module_name: module_name)).to eq("T.nilable(String)")
    end
  end
end
