$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('.', __dir__))

require 'test/unit'
require 'ruby_class_extract'
require 'fake_display'
require 'fake_led'

APPLICATION_RB = File.expand_path(
  '../mrbgems/picoruby-stackchan-protocol/examples/application.rb', __dir__
)

# Stub on-device Machine module so SCServo#read_bytes deadline logic works on host.
# delay_ms advances a monotonic counter; uptime_us returns it so timeouts resolve
# after READ_TIMEOUT_MS iterations of the poll loop.
unless defined?(Machine)
  module Machine
    @@offset_us = 0
    def self.uptime_us; @@offset_us; end
    def self.delay_ms(ms); @@offset_us += ms * 1_000; end
  end
end

# Pre-declare on-device-only base classes so RubyClassExtract can compare
# against them without actually loading BLE etc.
Object.const_set(:BLE, Class.new) unless defined?(BLE)

# Pre-declare UART module so SCServo's `require 'uart'` resolves on host
Object.const_set(:UART, Module.new) unless defined?(UART)

# Pre-define ILI9342::Color and other on-device constants referenced by Face
# class bodies. Application code references these as bare constants inside
# class definitions, so they must resolve at load time.
unless defined?(ILI9342)
  module ILI9342
    module Color
      WHITE = 0xFFFF
      BLACK = 0x0000
    end
  end
end

# Load all class/module definitions from application.rb that are not
# BLE-derived (StackChanApp itself uses on-device BLE API and is skipped).
RubyClassExtract.load_classes_from(APPLICATION_RB, exclude_superclasses: %w[BLE])

require 'fake_uart'

# Load the picoruby-scservo gem's pure Ruby class from the mrbgems tree
SCSERVO_PATH = File.expand_path(
  '../mrbgems/picoruby-scservo/mrblib/scservo.rb', __dir__
)
load SCSERVO_PATH
