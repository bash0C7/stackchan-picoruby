require_relative "lib/stackchan_ble_client/version"

Gem::Specification.new do |spec|
  spec.name          = "stackchan_ble_client"
  spec.version       = StackchanBleClient::VERSION
  spec.authors       = ["bash0C7"]
  spec.summary       = "BLE control SDK for the M5Stack StackChan PicoRuby firmware"
  spec.description   = <<~DESC
    High-level BLE client for the StackChan PicoRuby firmware. Connects via Nordic UART
    Service (NUS) and exposes a block DSL (#send do |stackchan| ... end) for face / LED
    frames with side, mode, and 4 color forms (named / RGB hex / HSB hex / mode keyword).
  DESC
  spec.required_ruby_version = ">= 3.1.0"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.executables = ["stackchan-ble-control"]
  spec.require_paths = ["lib"]
end
