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
