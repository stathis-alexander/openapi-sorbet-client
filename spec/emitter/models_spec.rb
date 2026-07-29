# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe OpenapiSorbetClient::Emitter do
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

  it "emits a gem skeleton and preserves model wire keys" do
    Dir.mktmpdir do |output|
      emit_fixture("operations.yaml", output)
      root = File.join(output, "oip_tax")
      models = File.read(File.join(root, "lib/oip_tax/models.rb"))

      expect(models).to include("class Pet < T::Struct")
      expect(models).to include("const :name, T.nilable(String)")
      expect(models).to include("WIRE_KEY_MAP")
      expect(models).to include('name: "Name"')
      expect(models).to include("include WireHelpers")
      expect(File.read(File.join(root, "sorbet/config"))).to include(
        "--enable-experimental-rbs-comments"
      )
      expect(File).to exist(File.join(root, "Gemfile"))
      expect(File).to exist(File.join(root, "oip_tax.gemspec"))
      gemspec = Gem::Specification.load(File.join(root, "oip_tax.gemspec"))
      expect { gemspec.validate }.not_to raise_error
      expect(gemspec.runtime_dependencies.map(&:name)).to contain_exactly(
        "faraday",
        "sorbet-runtime"
      )
      %w[version.rb errors.rb client.rb models.rb].each do |file_name|
        expect(File).to exist(File.join(root, "lib/oip_tax", file_name))
      end
      expect(File).to exist(File.join(root, "lib/oip_tax/models/wire_helpers.rb"))
      expect(File.read(File.join(root, "lib/oip_tax/client.rb"))).to include(
        "class Client"
      )
    end
  end

  it "emits enums with their wire values" do
    Dir.mktmpdir do |output|
      emit_fixture("enums_nullable.yaml", output)
      root = File.join(output, "oip_tax")
      models = File.read(File.join(root, "lib/oip_tax/models.rb"))

      expect(models).to include("class Status < T::Enum")
      expect(models).to include('Available = new("available")')
      expect(models).to include('Pending = new("pending")')
      expect(models).to include("deserialize(value)")
      expect(models).to include("serialize")
    end
  end

  it "does not emit invalid trailing :: for nameless inline objects" do
    Dir.mktmpdir do |output|
      emit_fixture("inline_nameless.yaml", output)
      root = File.join(output, "oip_tax")
      models = File.read(File.join(root, "lib/oip_tax/models.rb"))

      expect(models).to include("T::Hash[String, T.untyped]")
      expect(models).not_to match(/::Models::[^A-Za-z]/)
      expect(models).not_to include("Models::\n")
      expect { RubyVM::InstructionSequence.compile(models) }.not_to raise_error
    end
  end

  it "emits load-safe models for mutual $ref cycles" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "mutual_refs.yaml",
        output,
        module_name: "MutualRefsGem",
        gem_name: "mutual_refs_gem"
      )
      root = File.join(output, "mutual_refs_gem")
      lib = File.join(root, "lib")

      expect(File).to exist(File.join(lib, "mutual_refs_gem/models.rb"))
      $LOAD_PATH.unshift(lib)
      expect { require "mutual_refs_gem" }.not_to raise_error
      expect(MutualRefsGem::Models::NodeA).to be < T::Struct
      expect(MutualRefsGem::Models::NodeB).to be < T::Struct
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end

  it "round-trips wire payloads with PascalCase keys at runtime" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "operations.yaml",
        output,
        module_name: "WireRoundTrip",
        gem_name: "wire_round_trip"
      )
      root = File.join(output, "wire_round_trip")
      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "wire_round_trip"

      pet = WireRoundTrip::Models::Pet.from_wire("Name" => "Rex")
      expect(pet.name).to eq("Rex")
      expect(pet.to_wire).to eq("Name" => "Rex")
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end

  it "round-trips enum wire values at runtime" do
    Dir.mktmpdir do |output|
      emit_fixture(
        "enums_nullable.yaml",
        output,
        module_name: "EnumRoundTrip",
        gem_name: "enum_round_trip"
      )
      root = File.join(output, "enum_round_trip")
      lib = File.join(root, "lib")
      $LOAD_PATH.unshift(lib)
      require "enum_round_trip"

      status = EnumRoundTrip::Models::Status.from_wire("available")
      expect(status).to eq(EnumRoundTrip::Models::Status::Available)
      expect(status.to_wire).to eq("available")

      listing = EnumRoundTrip::Models::Listing.from_wire("status" => "pending")
      expect(listing.status).to eq(EnumRoundTrip::Models::Status::Pending)
      expect(listing.to_wire).to eq("status" => "pending")
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end
end
