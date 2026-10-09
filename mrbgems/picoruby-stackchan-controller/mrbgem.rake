MRuby::Gem::Specification.new('picoruby-stackchan-controller') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan controller engine: BLE central, daemon, CLI and calibration'
  spec.add_dependency 'picoruby-stackchan-protocol'
  spec.add_dependency 'picoruby-ble'
  spec.add_dependency 'picoruby-drb-ble'
  spec.add_dependency 'picoruby-json'
end
