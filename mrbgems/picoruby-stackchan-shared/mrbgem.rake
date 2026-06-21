MRuby::Gem::Specification.new('picoruby-stackchan-shared') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan shared pure-Ruby layer (frame codec / face & LED tables / HSB / AI frame text), usable by both the device firmware and the PC daemon'

  # Pure Ruby; the gem build bundles every mrblib/**/*.rb into bytecode. No C
  # extension, no sibling `require` (on-device PicoRuby does not put mrblib on
  # $LOAD_PATH). stackchan.rb (the namespace root) must load before the files
  # that reopen `module Stackchan::*`; MRuby::Gem loads mrblib in sorted path
  # order, and "stackchan.rb" sorts before "stackchan/..." so the parent module
  # is defined first.
end
