$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('.', __dir__))

require 'test/unit'
require 'ruby_class_extract'
require 'fake_display'
require 'fake_led'

APPLICATION_RB = File.expand_path(
  '../mrbgems/picoruby-stackchan-protocol/examples/application.rb', __dir__
)

# Pre-declare on-device-only base classes so RubyClassExtract can compare
# against them without actually loading BLE etc.
Object.const_set(:BLE, Class.new) unless defined?(BLE)

# Pre-define ILI9342::Color and other on-device constants referenced by Face
# class bodies. Application code references these as bare constants inside
# class definitions, so they must resolve at load time.
unless defined?(ILI9342)
  module ILI9342
    module Color
      WHITE = 0xFFFF
    end
  end
end

# Load all class/module definitions from application.rb that are not
# BLE-derived (StackChanApp itself uses on-device BLE API and is skipped).
RubyClassExtract.load_classes_from(APPLICATION_RB, exclude_superclasses: %w[BLE])
