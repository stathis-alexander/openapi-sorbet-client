# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

RSpec.describe OpenapiSorbetClient::Parser, "loading" do
  def fixture(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end

  it "loads document metadata from YAML" do
    document = described_class.parse(fixture("minimal.yaml"))

    expect(document.title).to eq("Minimal Pet")
    expect(document.version).to eq("0.1.0")
    expect(document.servers).to eq(["https://example.com/v1"])
    expect(document.operations).to eq([])
    expect(document.security_schemes).to eq({})
    expect(document.default_security).to eq([])
  end

  it "loads JSON documents" do
    path = File.join(Dir.tmpdir, "openapi-sorbet-client-#{Process.pid}.json")
    File.write(path, JSON.generate(
      "openapi" => "3.1.0",
      "info" => { "title" => "JSON API", "version" => "1.2.3" },
      "paths" => {}
    ))

    document = described_class.parse(path)

    expect(document.title).to eq("JSON API")
    expect(document.version).to eq("1.2.3")
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
