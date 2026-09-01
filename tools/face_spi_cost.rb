#!/usr/bin/env ruby
# What each face asks of the SPI bus, counted on the host with no device attached.
#
# This counts calls. It does not predict latency, and the call count is not what
# sets it: on a CoreS3, composing a face offscreen took a redraw from 207-428
# SPI#write calls down to 10 and moved the BLE `face` verb by 7-9%. The time goes
# into PicoRuby executing the geometry, not into the transfer. See "Latency and
# remaining headroom" in the README.
#
# Use it to compare one geometry or driver change against another without
# touching the robot, and measure latency itself with tools/face_profile.zsh.
#
#   ruby tools/face_spi_cost.rb
#
# ILI9342_MRBLIB overrides where the driver is read from (see below for the
# default resolution order).
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
# picoruby-ili9342 is fetched by R2P2-ESP32's build_config as a build-time
# mrbgem (from GitHub), not vendored here as a repo tree, so it has to be
# located rather than required — same resolution order as SCSERVO_RB in
# test/picotest/harness.rb: explicit override, sibling clone, build fetch copy.
ILI9342_SIBLING  = File.expand_path("../picoruby-ili9342/mrblib/ili9342.rb", ROOT)
ILI9342_VENDORED = File.join(ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32",
                              "picoruby", "build", "repos", "esp32-picoruby", "picoruby-ili9342",
                              "mrblib", "ili9342.rb")
DRIVER = ENV["ILI9342_MRBLIB"] || [ILI9342_SIBLING, ILI9342_VENDORED].find { |path| File.exist?(path) }
unless DRIVER && File.exist?(DRIVER)
  # Name the path that actually failed; an override pointing nowhere is the case
  # worth reporting, and listing the fallbacks instead hides it.
  searched = ENV["ILI9342_MRBLIB"] ? [ENV["ILI9342_MRBLIB"]] : [ILI9342_SIBLING, ILI9342_VENDORED]
  abort "ili9342.rb not found; searched:\n  " + searched.join("\n  ") +
        "\nSet ILI9342_MRBLIB to point at picoruby-ili9342's mrblib/ili9342.rb."
end

$LOAD_PATH.unshift File.join(ROOT, "lib")

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

puts format("%-10s %-18s %8s %8s %9s", "face", "path", "calls", "frames", "bytes")
rows.each do |name, path, calls, frames, bytes|
  puts format("%-10s %-18s %8d %8d %9d", name, path, calls, frames, bytes)
end
