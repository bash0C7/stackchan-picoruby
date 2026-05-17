require_relative "lib/stackchan_notifier/version"

Gem::Specification.new do |spec|
  spec.name          = "stackchan_notifier"
  spec.version       = StackchanNotifier::VERSION
  spec.authors       = ["bash0C7"]
  spec.summary       = "Claude Code → StackChan BLE notification bridge"
  spec.description   = <<~DESC
    Long-running Mac daemon that bridges Claude Code hook events to the StackChan
    BLE NUS combo frame (face + LED). Uses Ractor + DRb + Rinda::TupleSpace
    (TupleSpace4Ractor pattern by 関 将俊 / seki/ts4r) so hook scripts stay
    sub-100ms thin clients while a single BLE connection is held in the daemon.
  DESC
  spec.required_ruby_version = ">= 3.3.0"
  spec.add_runtime_dependency "rinda"
  spec.add_runtime_dependency "logger"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.executables = ["stackchan-notifier-daemon", "stackchan-notify"]
  spec.require_paths = ["lib"]
end
