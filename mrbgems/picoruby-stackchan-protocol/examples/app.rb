# examples/app.rb — autostart entry point. Copy this to /home/app.rb on the
# device (via picomodem upload, see docs/STACKCHAN_PROTOCOL_VERIFICATION.md).
#
# Pin layout matches mrbgems/picoruby-ili9342/examples/face_neutral.rb.
# rst_pin / bl_pin are placeholders until AW9523 / AXP2101 drivers exist.

require 'spi'
require 'gpio'
require 'ili9342'
require 'stackchan-protocol'

SCK_PIN  = 36
MOSI_PIN = 37
CS_PIN   = 3
DC_PIN   = 35
RST_PIN  = 1   # placeholder — AW9523 P1.1 routes the real LCD reset
BL_PIN   = 2   # placeholder — AXP2101 routes the real backlight

# NOTE: cs_pin: omitted from SPI.new — driver manages CS manually so the
# cmd→DC change→data window stays in a single CS-low frame.
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

# Welcome face before any host command arrives.
StackchanProtocol::Face::Neutral.new.draw(display)

StackchanProtocol::Dispatcher.new(display: display).run
