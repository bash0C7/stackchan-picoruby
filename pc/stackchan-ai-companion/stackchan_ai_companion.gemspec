Gem::Specification.new do |spec|
  spec.name                  = "stackchan_ai_companion"
  spec.version               = "0.1.0"
  spec.authors               = ["bash0C7"]
  spec.summary               = "StackChan AI companion: Mac Foundation Model reply -> BLE subtitle frame"
  spec.required_ruby_version = ">= 3.1.0"
  spec.files                 = Dir["lib/**/*.rb", "exe/*"]
  spec.executables           = ["stackchan-ai-companion"]
  spec.require_paths         = ["lib"]
end
