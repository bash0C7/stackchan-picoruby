require_relative "lib/stackchan_protocol/version"

Gem::Specification.new do |spec|
  spec.name        = "stackchan-protocol"
  spec.version     = StackchanProtocol::VERSION
  spec.authors     = ["bash0C7"]
  spec.summary     = "Host-side client for the StackChan USB-serial 1-byte protocol"
  spec.license     = "MIT"

  spec.files       = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.executables = ["stackchan-control", "picomodem-upload"]
  spec.bindir      = "exe"
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "uart", "~> 1.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "test-unit", "~> 3.6"
end
