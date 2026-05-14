# examples/app.rb — autostart entry for StackChan AI base.
#
# Cold-boot init must run BEFORE LCD or LED traffic:
#   1. AXP2101 PMIC must enable DLDO1 (LCD power + backlight rail).
#   2. AW9523 IO Expander P1.1 must be pulsed to release LCD reset.
#   3. PY32 IO Expander handles LED data internally; no separate enable needed.
# A cold-boot (USB unplug) leaves DLDO1 OFF, so the LCD init block is mandatory.

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-led'
require 'stackchan-protocol'

I2C_SDA_PIN  = 12
I2C_SCL_PIN  = 11
AXP2101_ADDR = 0x34
AW9523_ADDR  = 0x58

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

# AXP2101: enable DLDO1 (bit 7 of reg 0x90) and set its voltage (reg 0x99).
i2c.write(AXP2101_ADDR, 0x90, 0xBF)
i2c.write(AXP2101_ADDR, 0x99, 24)

# AW9523: P1 push-pull output, then pulse LCD RST (P1.1).
i2c.write(AW9523_ADDR, 0x04, 0b00011000)
i2c.write(AW9523_ADDR, 0x05, 0b00001100)
i2c.write(AW9523_ADDR, 0x11, 0b00010000)
i2c.write(AW9523_ADDR, 0x03, 0b10000001)
Machine.delay_ms(20)
i2c.write(AW9523_ADDR, 0x03, 0b10000011)
Machine.delay_ms(10)

# ILI9342 SPI bus + display init.
SCK_PIN       = 36
MOSI_PIN      = 37
CS_PIN        = 3
DC_PIN        = 35
DUMMY_RST_PIN = 1
DUMMY_BL_PIN  = 2

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

# PY32 IO Expander + LED driver. PY32 boots slowly after power-on (~1.2s per
# official firmware hal_io_expander.cpp); retry the first I2C write until it ACKs.
Machine.delay_ms(500)
py32 = PY32IOExpander.new(i2c)
led_init_attempt = 0
begin
  led = StackchanLed.new(py32)
rescue IOError
  led_init_attempt += 1
  if led_init_attempt < 6
    Machine.delay_ms(200)
    retry
  end
  raise
end
# Low brightness during bring-up to protect eyes / equipment.
led.brightness = 20

# Initial face: neutral.
StackchanProtocol::Face::Neutral.new.draw(display)

# Frame protocol: parser + dispatcher.
parser     = StackchanProtocol::FrameParser.new
dispatcher = StackchanProtocol::Dispatcher.new(display: display, led: led)

TICK_MS = 50
loop do
  tick_start_ms = Machine.uptime_us / 1000
  chunk = STDIN.read_nonblock(256)
  if chunk
    parser.feed(chunk).each { |f| dispatcher.handle(f) }
  end
  led.tick(tick_start_ms)
  elapsed = (Machine.uptime_us / 1000) - tick_start_ms
  remaining = TICK_MS - elapsed
  sleep_ms(remaining) if remaining > 0
end
