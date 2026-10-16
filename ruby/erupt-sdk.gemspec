# frozen_string_literal: true

require_relative "lib/erupt/version"

Gem::Specification.new do |spec|
  spec.name = "erupt-sdk"
  spec.version = Erupt::VERSION
  spec.summary = "Serve Ruby models as an erupt admin UI through an erupt cloud server"
  spec.description = "An erupt cloud node: declare models in Ruby, the erupt server renders the admin UI. " \
                     "Rack compatible, with a built-in HTTP server; no runtime dependencies."
  spec.authors = ["YuePeng"]
  spec.homepage = "https://github.com/erupt-io/erupt-sdk/tree/main/ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = { "source_code_uri" => "https://github.com/erupt-io/erupt-sdk", "rubygems_mfa_required" => "true" }
  spec.files = Dir["lib/**/*.{rb,json}", "sig/**/*.rbs", "README.md"]
  spec.require_paths = ["lib"]
end
