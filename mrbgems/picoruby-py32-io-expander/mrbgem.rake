MRuby::Gem::Specification.new('picoruby-py32-io-expander') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'PY32 IO Expander driver (M5Stack StackChan AI base) - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
