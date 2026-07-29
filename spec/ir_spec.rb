# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenapiSorbetClient::IR do
  it "builds a document with keyword init" do
    doc = described_class::Document.new(
      title: "Demo",
      version: "1.0",
      servers: ["https://example.com"],
      schemas: {},
      operations: [],
      security_schemes: {},
      default_security: []
    )
    expect(doc.title).to eq("Demo")
  end
end
