# examples/benchmark_fill.rb — measure fill() latency averaged over 5 runs.
require 'spi'
require 'gpio'
require 'ili9342'

SCK_PIN  = 36
MOSI_PIN = 37
CS_PIN   = 3
DC_PIN   = 35
RST_PIN  = 1   # placeholder — see black_fill.rb header
BL_PIN   = 2   # placeholder

# NOTE: cs_pin: omitted from SPI.new — see black_fill.rb header.
spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, mode: 2)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

ITER = 5
total_us = 0
ITER.times do
  start = Machine.uptime_us
  display.fill(ILI9342::Color::BLACK)
  total_us += Machine.uptime_us - start
end

avg_ms = (total_us.to_f / ITER) / 1000.0
puts "fill() x#{ITER} avg: #{avg_ms.round(2)} ms"
