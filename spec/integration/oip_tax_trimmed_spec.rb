# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe "trimmed OIP Tax fixture integration", :aggregate_failures do
  def fixture_path
    File.expand_path("../fixtures/openapi/oip_tax_trimmed.yaml", __dir__)
  end

  it "parses, emits, and round-trips Returns + CalculateReturn offline" do
    document = OpenapiSorbetClient::Parser.parse(fixture_path)

    method_names = document.operations.map(&:method_name)
    expect(method_names).to include("get_returns", "post_calculate_return")

    tax_return_info = document.schemas.fetch("TaxReturnInfo")
    return_id = tax_return_info.properties.find { |property| property.name == "return_id" }
    expect(return_id).not_to be_nil
    expect(return_id.wire_key).to eq("ReturnID")

    configuration_xml = document.schemas.fetch("CalculateReturnRequest").properties.find do |property|
      property.name == "configuration_xml"
    end
    expect(configuration_xml).not_to be_nil
    expect(configuration_xml.wire_key).to eq("ConfigurationXml")
    expect(configuration_xml.schema.ruby_type).to eq("String")

    Dir.mktmpdir do |output|
      OpenapiSorbetClient::Emitter.new(
        document: document,
        output: output,
        module_name: "OipTaxTrimmed",
        gem_name: "oip_tax_trimmed"
      ).emit

      root = File.join(output, "oip_tax_trimmed")
      models_src = File.read(File.join(root, "lib/oip_tax_trimmed/models.rb"))
      expect(models_src).to include("class TaxReturnInfo < T::Struct")
      expect(models_src).to include("const :return_id, T.nilable(String)")
      expect(models_src).to include('return_id: "ReturnID"')
      expect(models_src).to include("const :configuration_xml, String")
      expect(models_src).to include('configuration_xml: "ConfigurationXml"')

      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "faraday"
      require "oip_tax_trimmed"

      expect(OipTaxTrimmed::Models::TaxReturnInfo::WIRE_KEY_MAP[:return_id]).to eq("ReturnID")
      expect(OipTaxTrimmed::Models::CalculateReturnRequest::WIRE_KEY_MAP[:configuration_xml])
        .to eq("ConfigurationXml")

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/taxservices/oiptax/api/v1/Returns") do |env|
        expect(env.request_headers["IntegratorKey"]).to eq("ik")
        expect(env.params["subscription-key"]).to eq("sk")
        expect(env.params["$filter"]).to eq("TaxYear eq '2021'")
        [
          200,
          { "Content-Type" => "application/json" },
          JSON.generate(
            "Returns" => [
              {
                "ReturnID" => "2021I:TEST1:V1",
                "TaxYear" => "2021",
                "ClientName" => "Doe, Jane"
              }
            ],
            "TotalCount" => 1
          )
        ]
      end

      stubs.post("/taxservices/oiptax/api/v1/CalculateReturn") do |env|
        wire = JSON.parse(env.body)
        expect(wire).to include(
          "ConfigurationXml" => "<TaxCalculateReturnOptions/>",
          "ReturnId" => ["2021I:TEST1:V1"]
        )
        [
          200,
          { "Content-Type" => "application/json" },
          JSON.generate(
            "ExecutionID" => "265118f1-c7fd-48d0-882e-831771eab1c7",
            "BatchFileResults" => [
              {
                "IsError" => false,
                "Messages" => ["{ReturnId} submitted successfully."],
                "SubItemExecutionIDs" => ["85046d61-6a8d-4642-a57e-ee38a9896d25"],
                "FileGroupID" => 0
              }
            ]
          )
        ]
      end

      connection = Faraday.new(url: "https://api.cchaxcess.com") do |faraday|
        faraday.adapter(:test, stubs)
      end

      client = OipTaxTrimmed::Client.new(
        base_url: "https://api.cchaxcess.com",
        integrator_key: "ik",
        subscription_key: "sk",
        connection: connection
      )

      response = client.get_returns(filter: "TaxYear eq '2021'")
      expect(response).to be_a(OipTaxTrimmed::Models::ReturnsResponse)
      expect(response.total_count).to eq(1)
      expect(response.returns.size).to eq(1)
      expect(response.returns.first).to be_a(OipTaxTrimmed::Models::TaxReturnInfo)
      expect(response.returns.first.return_id).to eq("2021I:TEST1:V1")
      expect(response.returns.first.tax_year).to eq("2021")

      request = OipTaxTrimmed::Models::CalculateReturnRequest.new(
        return_id: ["2021I:TEST1:V1"],
        configuration_xml: "<TaxCalculateReturnOptions/>"
      )
      batch = client.post_calculate_return(body: request)
      expect(batch).to be_a(OipTaxTrimmed::Models::BatchSubmissionResponse)
      expect(batch.execution_id).to eq("265118f1-c7fd-48d0-882e-831771eab1c7")
      expect(batch.batch_file_results.first.is_error).to eq(false)

      stubs.verify_stubbed_calls
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end
end
