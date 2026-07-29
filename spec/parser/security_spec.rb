# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenapiSorbetClient::Parser, "security" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "parses API key security schemes by component name" do
    schemes = described_class.parse(fixture("operations.yaml")).security_schemes

    expect(schemes.fetch("apiKeyHeader").to_h).to eq(
      name: "apiKeyHeader",
      type: :api_key,
      api_key_name: "IntegratorKey",
      location: :header,
      description: "Integrator API key"
    )
    expect(schemes.fetch("apiKeyQuery").to_h).to include(
      name: "apiKeyQuery",
      type: :api_key,
      api_key_name: "subscription-key",
      location: :query
    )
  end

  it "preserves OR-of-AND default security semantics" do
    document = described_class.parse(fixture("operations.yaml"))

    expect(document.default_security).to eq([["apiKeyHeader"], ["apiKeyQuery"]])
  end
end
