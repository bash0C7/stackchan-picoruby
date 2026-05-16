MRuby::Gem::Specification.new('picoruby-stackchan-led') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan AI 12-pixel LED driver with 4-mode animation - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-py32-io-expander'
  spec.add_test_dependency 'picoruby-picotest'
end
