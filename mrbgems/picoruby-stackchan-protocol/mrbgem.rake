MRuby::Gem::Specification.new('picoruby-stackchan-protocol') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan ⇔ PC USB-serial frame protocol dispatcher with face + LED'

  spec.add_dependency 'picoruby-ili9342'
  spec.add_dependency 'picoruby-stackchan-led'
  spec.add_test_dependency 'picoruby-picotest'
end
