# frozen_string_literal: true

require "thor"

module OpenapiSorbetClient
  class CLI < Thor
    desc "generate", "Generate a Faraday/Sorbet client gem from an OpenAPI 3 spec"
    method_option :spec, type: :string, required: true
    method_option :output, type: :string, required: true
    method_option :module, type: :string, required: true
    method_option :"gem-name", type: :string, required: true
    def generate
      document = Parser.parse(options[:spec])
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
