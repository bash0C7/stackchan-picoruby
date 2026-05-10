MRuby::Gem::Specification.new('picoruby-ili9342') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'ILI9342 LCD driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-spi'
  spec.add_dependency 'picoruby-gpio'
  spec.add_dependency 'picoruby-machine'
  spec.add_test_dependency 'picoruby-picotest'
end
