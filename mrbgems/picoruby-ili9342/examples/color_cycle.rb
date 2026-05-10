# examples/color_cycle.rb — cycles RED → GREEN → BLUE every 1 second.
require 'spi'
require 'gpio'
require 'ili9342'

SCK_PIN  = 36
MOSI_PIN = 37
CS_PIN   = 3
DC_PIN   = 35
RST_PIN  = 1   # placeholder — see black_fill.rb header
BL_PIN   = 2   # placeholder

spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 0)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

[ILI9342::Color::RED, ILI9342::Color::GREEN, ILI9342::Color::BLUE].each do |color|
  display.fill(color)
  sleep 1
end
