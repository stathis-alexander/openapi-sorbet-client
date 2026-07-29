# frozen_string_literal: true

require "openapi_sorbet_client"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.filter_run_when_matching :focus
  config.order = :random
end
