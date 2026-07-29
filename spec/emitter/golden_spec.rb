# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OpenapiSorbetClient::Emitter, "golden files" do
  def emit_fixture(fixture, output, module_name: "OipTax", gem_name: "oip_tax")
    document = OpenapiSorbetClient::Parser.parse(
      File.expand_path("../fixtures/openapi/#{fixture}", __dir__)
    )

    described_class.new(
      document: document,
      output: output,
      module_name: module_name,
      gem_name: gem_name
    ).emit
  end

  def golden_snippet(name)
    path = File.expand_path("../golden/minimal/#{name}", __dir__)
    File.read(path).strip
  end

  it "includes the golden Pet model fragment from minimal.yaml" do
    Dir.mktmpdir do |output|
      emit_fixture("minimal.yaml", output)
      models = File.read(File.join(output, "oip_tax/lib/oip_tax/models.rb"))

      expect(models).to include(golden_snippet("pet_model_snippet.rb"))
    end
  end

  it "includes the golden get_pet client fragment from operations.yaml" do
    Dir.mktmpdir do |output|
      emit_fixture("operations.yaml", output)
      client = File.read(File.join(output, "oip_tax/lib/oip_tax/client.rb"))

      expect(client).to include(golden_snippet("client_snippet.rb"))
    end
  end
end
