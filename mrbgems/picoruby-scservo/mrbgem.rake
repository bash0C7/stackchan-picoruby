MRuby::Gem::Specification.new('picoruby-scservo') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'FEETECH SCServo SCSCL series UART driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-uart'
  spec.add_test_dependency 'picoruby-picotest'
end
