#!/usr/bin/env ruby
# What each face costs the LCD, measured on the host with no device attached.
#
# On a CoreS3 on 2026-09-01, six faces x eight rounds over the BLE `face` verb
# fit this law:
#
#     latency = 0.181 s + 0.853 ms * (number of SPI#write calls)   R^2 = 0.991
#
# The intercept lands on the independently measured 0.175 s floor (the `led`
# verb: same BLE path, no LCD work). Fitting against RAMWR transactions instead
# gives a similar R^2 but a 0.199 s intercept — it cannot see the extra chunk
# writes a large fill carries. Fitting against bytes sent explains nothing
# (R^2 = 0.118): a call costs the same whatever it carries.
#
# So the number below, not the pixel count, is what a face costs. This script
# drives the real ILI9342 driver with a counting SPI so that number can be
# checked after a geometry or driver change without touching the robot.
#
#   ruby tools/face_spi_cost.rb
#
# ILI9342_MRBLIB overrides where the driver is read from; it is a build-time
# mrbgem fetched from GitHub, not vendored here, so the default points at the
# author's checkout the same way test/picotest/harness.rb points at scservo.
require "rbconfig"

ROOT   = File.expand_path("..", __dir__)
DRIVER = ENV["ILI9342_MRBLIB"] ||
         "/Users/bash/dev/src/github.com/bash0C7/picoruby-ili9342/mrblib/ili9342.rb"
abort "driver not found: #{DRIVER} (set ILI9342_MRBLIB)" unless File.exist?(DRIVER)

$LOAD_PATH.unshift File.join(ROOT, "lib")

MS_PER_CALL = 0.853
FLOOR_S     = 0.181
RAMWR       = 0x2C

class CountingPin
  attr_reader :value
  def initialize = @value = 1
  def write(v) = @value = v
end

# Counts what the driver asks of the SPI bus. Commands are the bytes written
# while DC is low, which is how a RAMWR frame is told from pixel data.
class CountingSPI
  attr_reader :calls, :frames, :bytes
  def initialize(dc_pin)
    @dc = dc_pin
    @calls = @frames = @bytes = 0
  end

  def write(*data)
    flat = data.flat_map { |d| coerce(d) }
    @frames += flat.count(RAMWR) if @dc.value == 0
    @calls  += 1
    @bytes  += flat.size
    flat.size
  end

  def reset!
    @calls = @frames = @bytes = 0
  end

  private

  def coerce(d)
    case d
    when Integer then [d & 0xFF]
    when String  then d.bytes
    when Array   then d.flat_map { |x| coerce(x) }
    else raise ArgumentError, "cannot coerce #{d.class}"
    end
  end
end

# PicoRuby runtime built-ins the driver expects to already exist.
module Machine
  def self.delay_ms(_ms); end
end
class SPI;  end unless defined?(SPI)
class GPIO; end unless defined?(GPIO)
$LOADED_FEATURES << "spi" << "gpio"

require DRIVER
require "ruby_class_extract"
RubyClassExtract.load_classes_from(File.join(ROOT, "app", "application.rb"),
                                   exclude_superclasses: %w[BLE])

F = StackchanApp::Face
FACES = { "neutral" => F::Neutral, "smile" => F::Smile, "joy" => F::Joy,
          "surprised" => F::Surprised, "sad" => F::Sad, "angry" => F::Angry,
          "closed" => F::Closed }.freeze

def display_with_counter
  dc  = CountingPin.new
  spi = CountingSPI.new(dc)
  d = ILI9342.new(spi: spi, dc_pin: dc, cs_pin: CountingPin.new,
                  rst_pin: CountingPin.new, bl_pin: CountingPin.new,
                  width: 320, height: 240)
  spi.reset!   # drop the init sequence; only the drawing is being priced
  [d, spi]
end

def measure(face_class, &block)
  d, spi = display_with_counter
  block.call(face_class.new, d)
  [spi.calls, spi.frames, spi.bytes]
end

rows = []
FACES.each do |name, klass|
  rows << [name, "redraw", *measure(klass) { |f, d| f.redraw(d) }]
end
rows << ["neutral", "draw (cold boot)", *measure(F::Neutral) { |f, d| f.draw(d) }]
rows << ["neutral", "blink close", *measure(F::Neutral) { |f, d| f.redraw_eyes_closed(d) }]
rows << ["neutral", "blink open",  *measure(F::Neutral) { |f, d| f.redraw_eyes_open(d) }]

puts format("%-10s %-18s %8s %8s %9s %12s", "face", "path", "calls", "frames", "bytes", "predicted")
rows.each do |name, path, calls, frames, bytes|
  puts format("%-10s %-18s %8d %8d %9d %9.3f s", name, path, calls, frames, bytes,
              FLOOR_S + calls * MS_PER_CALL / 1000.0)
end
puts
puts "predicted = #{FLOOR_S} s floor + #{MS_PER_CALL} ms per SPI#write call"
