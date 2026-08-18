# frozen_string_literal: true

require "thor"

module OpenapiSorbetClient
  class CLI < Thor
    desc "generate", "Generate a Faraday/Sorbet client gem from an OpenAPI 2/3 spec"
    method_option :spec, type: :string, required: true
    method_option :output, type: :string, required: true
    method_option :module, type: :string, required: true
    method_option :"gem-name", type: :string, required: true
    method_option :"synthesize-from-examples", type: :boolean, default: true,
                  desc: "When a media type has no schema, infer one from example/examples (default: true)"
    method_option :overrides, type: :string,
                  desc: "Path to a YAML overrides file correcting spec/API mismatches (see Overrides docs)"
    def generate
      document = Parser.parse(
        options[:spec],
        synthesize_from_examples: options[:"synthesize-from-examples"] != false
      )
      document = Overrides.load(options[:overrides]).apply(document)
      Emitter.new(
        document: document,
        output: options[:output],
        module_name: options[:module],
        gem_name: gem_name_option
      ).emit
      say "Generated #{gem_name_option} in #{options[:output]}"
    end

    private

    def gem_name_option
      options[:"gem-name"] || options[:gem_name]
    end
  end
end
