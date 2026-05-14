# examples/app.rb — autostart entry point. Copy this to /home/app.rb on the
# device (via picomodem upload, see docs/STACKCHAN_PROTOCOL_VERIFICATION.md).
#
# CoreS3 LCD requires three external initialisations via the system I2C bus
# before SPI traffic does anything visible:
#   1. AXP2101 PMIC must enable DLDO1 (LCD power + backlight rail).
#   2. AW9523 IO Expander P1.1 must be pulsed to release LCD reset.
#   3. Only then does the ILI9342 panel respond to SPI commands.
# A cold-boot (USB unplug) leaves DLDO1 OFF, so omitting this block produces
# a black screen even though the SPI init completes silently.

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'ili9342'
require 'stackchan-protocol'

I2C_SDA_PIN  = 12
I2C_SCL_PIN  = 11
AXP2101_ADDR = 0x34
AW9523_ADDR  = 0x58

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 400_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

# AXP2101: enable DLDO1 (bit 7 of reg 0x90) and set its voltage (reg 0x99).
# Value 24 follows upstream's 20 + brightness*8/100 mapping at ~50%.
i2c.write(AXP2101_ADDR, 0x90, 0xBF)
i2c.write(AXP2101_ADDR, 0x99, 24)

# AW9523: P1 as push-pull output, then pulse LCD RST (P1.1).
# Mirror of upstream Aw9523::ResetIli9342() (stackchan.cc:168).
i2c.write(AW9523_ADDR, 0x04, 0b00011000)  # CONFIG_P0
i2c.write(AW9523_ADDR, 0x05, 0b00001100)  # CONFIG_P1 — P1.1 = output
i2c.write(AW9523_ADDR, 0x11, 0b00010000)  # GCR — P0 push-pull
i2c.write(AW9523_ADDR, 0x03, 0b10000001)  # P1 = LCD RST low
Machine.delay_ms(20)
i2c.write(AW9523_ADDR, 0x03, 0b10000011)  # P1 = LCD RST high
Machine.delay_ms(10)

# ILI9342 SPI bus + display init.
# rst_pin / bl_pin are driven onto unused GPIOs because the real reset and
# backlight live on AW9523 / AXP2101 (handled above). The driver still
# requires GPIO objects, so we point them at free pins.
SCK_PIN       = 36
MOSI_PIN      = 37
CS_PIN        = 3
DC_PIN        = 35
DUMMY_RST_PIN = 1   # AW9523 P1.1 is the real reset
DUMMY_BL_PIN  = 2   # AXP2101 DLDO1 is the real backlight

spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, mode: 2)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(DUMMY_RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(DUMMY_BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

faces = [
  StackchanProtocol::Face::Neutral.new,
  StackchanProtocol::Face::Smile.new,
  StackchanProtocol::Face::Joy.new,
  StackchanProtocol::Face::Surprised.new,
]
loop do
  faces.each do |face|
    face.draw(display)
    Machine.delay_ms(1500)
  end
end
