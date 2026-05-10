# examples/black_fill.rb — fill the screen black, the simplest "it works" demo.
require 'spi'
require 'gpio'
require 'ili9342'

# CoreS3 pin numbers (verified from upstream stackchan.cc; see
# mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md).
SCK_PIN  = 36
MOSI_PIN = 37
CS_PIN   = 3
DC_PIN   = 35
# RST and BL are NOT direct GPIOs on real CoreS3 hardware (AW9523 IO Expander
# / AXP2101 PMIC). Placeholder GPIOs below let the script run end-to-end;
# software SWRESET (init cmd 0x01) substitutes for HW reset, and USB power
# keeps the backlight on.
RST_PIN  = 1
BL_PIN   = 2

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

display.fill(ILI9342::Color::BLACK)
