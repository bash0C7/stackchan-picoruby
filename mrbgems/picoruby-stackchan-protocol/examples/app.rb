# examples/app.rb — bring-up smoke (v13-aw9523-p0).
#
# Pared down to the minimum that proves cold-boot LED + face works WITHOUT
# any host-serial interaction. No STDIN.read_nonblock, no parser, no
# dispatcher, no led.tick. The only loop is `sleep + puts heartbeat`.
#
# Goals (verifiable purely by looking at the device + serial trace):
#   (a) LCD shows the neutral face.
#   (b) All 12 WS2812 LEDs on the ring light up vivid RED at boot
#       (brightness=100).
#   (c) Serial console emits boot trace + `[tick N]` every 2s.
#
# When (a)+(b)+(c) are confirmed, frame protocol is re-introduced in a
# follow-up app version.
#
# Cold-boot order (mirrors StackChan-BSP hal_io_expander.cpp):
#   1. AXP2101 DLDO1 enable + voltage  (LCD power rail)
#   2. AW9523 P1 push-pull + LCD reset pulse
#   3. ILI9342 SPI bring-up
#   4. PY32 boot wait + REG_VERSION alive check
#   5. PY32 GPIO 0 (VM_EN) HIGH  ← powers servo + WS2812 rail
#   6. StackchanLed.new (GPIO 13 push-pull, count 12, internal blank)
#   7. Pair the blank with a 50ms-later second show (reference parity)
#   8. brightness=100, fill(255,0,0), show  ← VIVID RED
#   9. Face::Neutral on display
#  10. sleep + heartbeat puts loop

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
PY32_ADDR    = 0x6F

puts ""
puts "[boot] app.rb start (smoke v10-axp2101-full)"

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

# AXP2101 PMIC full init mirrors StackChan reference firmware/main/hal/board/stackchan.cc:50-72.
# 0x90 (LDO enable) alone is not enough — ALDO1/ALDO2 must be voltage-set
# (reg 0x94/0x95 = 28 → 3.3V) or the rails powering PY32-side peripherals
# (incl. WS2812 chain) stay collapsed even with VM_EN high.
i2c.write(AXP2101_ADDR, 0x97, 0x1C)   # ALDO4 voltage (28 → 3.3V)
i2c.write(AXP2101_ADDR, 0x69, 0x35)   # charger constant current default
i2c.write(AXP2101_ADDR, 0x30, 0x3F)   # button-battery / GPIO defaults
i2c.write(AXP2101_ADDR, 0x90, 0xBF)   # LDO ON: DLDO1 + ALDO1-4 + BLDO1-2
i2c.write(AXP2101_ADDR, 0x94, 28)     # ALDO1 voltage (28 → 3.3V) — VDD3V3 rail
i2c.write(AXP2101_ADDR, 0x95, 28)     # ALDO2 voltage (28 → 3.3V) — peripheral rail
i2c.write(AXP2101_ADDR, 0x27, 0x00)   # power-off thresholds
i2c.write(AXP2101_ADDR, 0x99, 24)     # DLDO1 voltage — LCD backlight

# AW9523 init mirrors stackchan.cc:148-156. Critical: P0 output (0x02 = 0b00000111)
# drives bit 0-2 HIGH which (per board schematic) appears to enable the WS2812
# 5V power rail. Without this v12 produced perfect PY32 LED_RAM (00 F8 ... = red
# 0xF800) and refresh fired, but the WS2812 chain stayed dark.
i2c.write(AW9523_ADDR, 0x02, 0b00000111)  # P0 output (WS2812 power enable etc.)
i2c.write(AW9523_ADDR, 0x03, 0b10000001)  # P1 output (LCD reset LOW, audio/etc HIGH)
i2c.write(AW9523_ADDR, 0x04, 0b00011000)  # CONFIG_P0
i2c.write(AW9523_ADDR, 0x05, 0b00001100)  # CONFIG_P1
i2c.write(AW9523_ADDR, 0x11, 0b00010000)  # GCR: P0 push-pull
i2c.write(AW9523_ADDR, 0x12, 0b11111111)  # LEDMODE_P0 (all GPIO mode)
i2c.write(AW9523_ADDR, 0x13, 0b11111111)  # LEDMODE_P1
Machine.delay_ms(20)
i2c.write(AW9523_ADDR, 0x03, 0b10000011)  # release LCD reset
Machine.delay_ms(10)
puts "[boot] AXP2101 (full) + AW9523 (with P0 enable) init done"

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
puts "[boot] ILI9342 init done"

puts "[boot] waiting 800ms for PY32..."
Machine.delay_ms(800)

ver_bytes = i2c.read(PY32_ADDR, 1, 0x02, timeout: 200)
if ver_bytes && ver_bytes.length > 0
  v = ver_bytes.bytes[0]
  puts sprintf("[boot] PY32 REG_VERSION = 0x%02X", v)
else
  puts "[boot] PY32 REG_VERSION read returned empty"
end

py32 = PY32IOExpander.new(i2c)

# VM_EN: WS2812 + servo power rail. Without HIGH, LED data line is irrelevant
# because the WS2812 chain has no Vcc. Per hal_io_expander.cpp:42-45.
py32.set_direction(0, true)
py32.set_pull_mode(0, true)
py32.digital_write(0, true)
Machine.delay_ms(200)
puts "[boot] VM_EN driven HIGH, +200ms settle"

led_init_attempt = 0
led = nil
begin
  led = StackchanLed.new(py32)
rescue IOError
  led_init_attempt += 1
  puts "[boot] StackchanLed.new failed, retry ##{led_init_attempt}"
  if led_init_attempt < 6
    Machine.delay_ms(200)
    retry
  end
  raise
end

# Reference paints all-off twice with a 50ms gap (hal_io_expander.cpp:53-55).
# StackchanLed.new already did the first show; do the second.
Machine.delay_ms(50)
led.show
puts "[boot] LED ring blanked (paired show)"

# VIVID RED at full brightness — bring-up smoke test signal.
led.brightness = 100
led.fill(255, 0, 0).show
puts "[boot] LED ring driven to vivid RED (255,0,0) at brightness=100"

StackchanProtocol::Face::Neutral.new.draw(display)
puts "[boot] Face::Neutral drawn"

# Snapshot the chips after the RED frame was supposedly emitted.
def hexdump_reg(label, addr, reg, length, i2c)
  data = i2c.read(addr, length, reg, timeout: 200)
  if data && data.length > 0
    bytes = data.bytes
    hex = bytes.map { |b| sprintf("%02X", b) }.join(" ")
    puts "  #{label} (0x#{sprintf("%02X", reg)}, #{length}B) = #{hex}"
  else
    puts "  #{label} (0x#{sprintf("%02X", reg)}) = <empty>"
  end
end

snapshot_lines = []
def snap(buf, line)
  buf << line
  puts line
end

snap(snapshot_lines, "[regdump] AXP2101:")
[0x90, 0x94, 0x95, 0x97, 0x99].each do |r|
  d = i2c.read(AXP2101_ADDR, 1, r, timeout: 200)
  v = (d && d.length > 0) ? d.bytes[0] : nil
  snap(snapshot_lines, sprintf("  0x%02X = %s", r, v ? sprintf("0x%02X", v) : "<empty>"))
end

snap(snapshot_lines, "[regdump] PY32 (after RED show):")
[[0x03, "GPIO_M_L"], [0x04, "GPIO_M_H "], [0x05, "GPIO_O_L"], [0x06, "GPIO_O_H "],
 [0x09, "GPIO_PU_L"], [0x0A, "GPIO_PU_H"],
 [0x13, "GPIO_DRV_L"], [0x14, "GPIO_DRV_H"], [0x24, "LED_CFG"]].each do |reg, name|
  d = i2c.read(PY32_ADDR, 1, reg, timeout: 200)
  v = (d && d.length > 0) ? d.bytes[0] : nil
  snap(snapshot_lines, sprintf("  0x%02X %-10s = %s", reg, name, v ? sprintf("0x%02X", v) : "<empty>"))
end

ram = i2c.read(PY32_ADDR, 6, 0x30, timeout: 200)
if ram && ram.length > 0
  rb = ram.bytes
  snap(snapshot_lines, sprintf("  0x30 LED_RAM (6B) = %02X %02X %02X %02X %02X %02X (pixel0/1/2 RGB565 LE)",
                               rb[0], rb[1], rb[2], rb[3], rb[4], rb[5]))
end

puts "[boot] heartbeat for ~10s, then exit"

n = 0
5.times do
  n += 1
  puts "[tick #{n}]"
  if n == 1
    # Repeat the dump on the first tick so a slow `cat` start can still capture it.
    snapshot_lines.each { |l| puts l }
  end
  Machine.delay_ms(2000)
end

puts "[boot] app.rb exiting normally — shell should return"
