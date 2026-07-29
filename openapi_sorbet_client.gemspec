# frozen_string_literal: true

require_relative "lib/openapi_sorbet_client/version"

Gem::Specification.new do |spec|
  spec.name = "openapi_sorbet_client"
  spec.version = OpenapiSorbetClient::VERSION
  spec.authors = ["Alexander Stathis"]
  spec.email = ["astathis@users.noreply.github.com"]
  spec.summary = "Generate Faraday + Sorbet Ruby client gems from OpenAPI 3.x"
  spec.description = spec.summary
  spec.homepage = "https://github.com/astathis/openapi-sorbet-client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject { |f| f.start_with?("spec/") }
  end
  spec.bindir = "exe"
  spec.executables = ["openapi-sorbet-client"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "sorbet-runtime", ">= 0.5"
  spec.add_development_dependency "faraday", "~> 2.0"
end
