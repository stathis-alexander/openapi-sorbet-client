# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "faraday"

RSpec.describe "overrides", :aggregate_failures do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "emits a typed filter-builder method using overridden field names" do
    document = OpenapiSorbetClient::Parser.parse(fixture("oip_tax_trimmed.yaml"))
    document = OpenapiSorbetClient::Overrides.load(fixture("oip_tax_overrides.yaml")).apply(document)

    get_returns = document.operations.find { |op| op.method_name == "get_returns" }
    expect(get_returns.odata_filter).not_to be_nil
    expect(get_returns.odata_filter.param_name).to eq("filter")

    field_names = get_returns.odata_filter.fields.map(&:name)
    expect(field_names).to include("tax_year", "client_id")

    tax_year_field = get_returns.odata_filter.fields.find { |f| f.name == "tax_year" }
    expect(tax_year_field.wire_name).to eq("TaxYear")
    expect(tax_year_field.required).to eq(true)

    client_id_field = get_returns.odata_filter.fields.find { |f| f.name == "client_id" }
    expect(client_id_field.wire_name).to eq("ClientID")
    expect(client_id_field.required).to eq(false)

    Dir.mktmpdir do |output|
      OpenapiSorbetClient::Emitter.new(
        document: document,
        output: output,
        module_name: "OipTaxOverridden",
        gem_name: "oip_tax_overridden"
      ).emit

      root = File.join(output, "oip_tax_overridden")
      client_src = File.read(File.join(root, "lib/oip_tax_overridden/client.rb"))
      expect(client_src).to include("def get_returns_by_filter(tax_year:, client_id: nil,")
      expect(client_src).to include(%("ClientID" + " eq '" + client_id + "'"))

      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "oip_tax_overridden"

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/taxservices/oiptax/api/v1/Returns") do |env|
        expect(env.params["$filter"]).to eq("TaxYear eq '2025' and ClientID eq 'TestClientId'")
        [200, { "Content-Type" => "application/json" }, '{"Returns":[],"TotalCount":0}']
      end
      connection = Faraday.new(url: "https://api.cchaxcess.com") { |f| f.adapter(:test, stubs) }
      client = OipTaxOverridden::Client.new(base_url: "https://api.cchaxcess.com", connection: connection)

      client.get_returns_by_filter(tax_year: "2025", client_id: "TestClientId")
      stubs.verify_stubbed_calls
    ensure
      $LOAD_PATH.delete(lib) if lib
      Object.send(:remove_const, :OipTaxOverridden) if defined?(OipTaxOverridden)
    end
  end

  it "leaves operations without a matching override untouched" do
    document = OpenapiSorbetClient::Parser.parse(fixture("oip_tax_trimmed.yaml"))
    document = OpenapiSorbetClient::Overrides.load(fixture("oip_tax_overrides.yaml")).apply(document)

    post_calculate_return = document.operations.find { |op| op.method_name == "post_calculate_return" }
    expect(post_calculate_return.odata_filter).to be_nil
  end

  it "is a no-op when no overrides path is given" do
    document = OpenapiSorbetClient::Parser.parse(fixture("oip_tax_trimmed.yaml"))
    document = OpenapiSorbetClient::Overrides.load(nil).apply(document)

    expect(document.operations.map(&:odata_filter).compact).to be_empty
  end
end
