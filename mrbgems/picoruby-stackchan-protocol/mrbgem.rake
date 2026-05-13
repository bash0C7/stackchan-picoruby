MRuby::Gem::Specification.new('picoruby-stackchan-protocol') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan ⇔ PC USB-serial 1-byte protocol dispatcher and procedural face renderer'

  spec.add_dependency 'picoruby-ili9342'
  spec.add_test_dependency 'picoruby-picotest'
end
