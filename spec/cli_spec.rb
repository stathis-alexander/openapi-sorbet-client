# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OpenapiSorbetClient::CLI do
  def fixture_path(name)
    File.expand_path("fixtures/openapi/#{name}", __dir__)
  end

  def run_generate(spec:, output:, module_name:, gem_name:)
    described_class.start(
      [
        "generate",
        "--spec", spec,
        "--output", output,
        "--module", module_name,
        "--gem-name", gem_name
      ]
    )
  end

  it "generates a client gem from minimal OpenAPI via CLI" do
    Dir.mktmpdir do |output|
      expect do
        run_generate(
          spec: fixture_path("minimal.yaml"),
          output: output,
          module_name: "MinimalPet",
          gem_name: "minimal_pet"
        )
      end.to output(include("Generated minimal_pet in #{output}")).to_stdout

      root = File.join(output, "minimal_pet")
      expect(File).to exist(File.join(root, "minimal_pet.gemspec"))
      models = File.read(File.join(root, "lib/minimal_pet/models.rb"))
      expect(models).to include("class Pet < T::Struct")
    end
  end

  it "generates operation methods from operations fixture via CLI" do
    Dir.mktmpdir do |output|
      run_generate(
        spec: fixture_path("operations.yaml"),
        output: output,
        module_name: "OipTax",
        gem_name: "oip_tax"
      )

      client = File.read(File.join(output, "oip_tax/lib/oip_tax/client.rb"))
      expect(client).to include("def get_pet(")
      expect(client).to include("def create_pet(")
    end
  end
end
