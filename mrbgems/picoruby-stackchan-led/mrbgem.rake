MRuby::Gem::Specification.new('picoruby-stackchan-led') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = '12-pixel WS2812 ring on the StackChan CoreS3 via the PY32 I/O expander'
  spec.add_dependency 'picoruby-py32-io-expander'
end
