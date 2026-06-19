# Phase 4 Spike A bring-up: I2S audio out + GPIO13 contention probe.
#
# Self-contained app.mrb payload (no BLE). Cold-boots the board, lights the
# WS2812 LEDs (PY32 path), then drives the AW88298 amp via I2C + the I2S TX
# (picoruby-i2s, SoC GPIO13 DOUT) to play a tone sweep and a canned mu-law clip.
# After audio it re-colors the LEDs to prove GPIO13 (I2S DOUT) did not break the
# WS2812 path (spec §7 GPIO13 probe). Fixed-time, exits to the shell.
#
# HITL pass = a human hears a recognizable beep sweep + a buzzy 440 Hz mu-law
# tone, AND the LEDs go green→(audio)→blue (still controllable after I2S).
#
# Deploy: rake r2p2:build_flash_appmrb SRC=app/bringup_i2s_tone.rb  (needs the
# picoruby-i2s gem registered + r2p2:setup; see Phase 4 plan T5/T8).

# [1] 5s escape hatch — crash-loop recovery window (matches application.rb).
sleep_ms 5000

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'ili9342'
require 'py32-io-expander'
require 'i2s'

# Native rate to prove first. If 8 kHz won't lock cleanly on the S3 clock tree
# (spec §5.4), flip to 16000 — the mu-law decode is rate-agnostic, only the
# I2S clock and the amp reg 0x06 change.
SAMPLE_RATE = 8000

# ============================================================
# === StackchanLed (verbatim from app/application.rb) ========
# ============================================================
class StackchanLed
  PIXEL_COUNT  = 12
  LED_DATA_PIN = 13   # PY32-internal index, NOT SoC GPIO13 (spec §4)

  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)

  def initialize(py32)
    @py32 = py32
    @brightness = 100
    @buffer = Array.new(PIXEL_COUNT) { [0, 0, 0] }
    @py32.set_direction(LED_DATA_PIN, true)
    @py32.set_pull_mode(LED_DATA_PIN, true)
    @py32.set_drive_mode(LED_DATA_PIN, false)
    @py32.set_led_count(PIXEL_COUNT)
    show
  end

  def fill(r, g, b)
    @buffer = Array.new(PIXEL_COUNT) { [r, g, b] }
    self
  end

  def brightness=(v)
    @brightness = clamp(v, 0, 100)
    self
  end

  def show
    pixels = @buffer.map { |rgb| apply_brightness(rgb[0], rgb[1], rgb[2]) }
    @py32.write_led_ram(pixels)
    @py32.refresh_leds
    self
  end

  private

  def apply_brightness(r, g, b)
    [r * @brightness / 100, g * @brightness / 100, b * @brightness / 100]
  end

  def clamp(v, lo, hi)
    v < lo ? lo : (v > hi ? hi : v)
  end
end

# ============================================================
# === Speaker (verbatim from app/application.rb) =============
# ============================================================
class Speaker
  ULAW_BIAS    = 0x84
  AW88298_ADDR = 0x36
  AW_RATE_TBL  = [4, 5, 6, 8, 10, 11, 15, 20, 22, 44]

  def self.ulaw_byte_to_linear(byte)
    u = (~byte) & 0xFF
    t = ((u & 0x0F) << 3) + ULAW_BIAS
    t = t << ((u & 0x70) >> 4)
    (u & 0x80) != 0 ? (ULAW_BIAS - t) : (t - ULAW_BIAS)
  end

  def self.ulaw_decode(ulaw)
    out = ""
    ulaw.each_byte do |b|
      v = ulaw_byte_to_linear(b) & 0xFFFF
      out << (v & 0xFF).chr
      out << ((v >> 8) & 0xFF).chr
    end
    out
  end

  def self.aw88298_reg06(sample_rate)
    rate = (sample_rate + 1102) / 2205
    idx = 0
    while rate > AW_RATE_TBL[idx]
      idx += 1
      break if idx >= AW_RATE_TBL.length
    end
    idx = AW_RATE_TBL.length - 1 if idx >= AW_RATE_TBL.length
    idx | 0x14C0
  end

  def self.aw88298_init_writes(sample_rate)
    [[0x61, 0x0673], [0x04, 0x4040], [0x05, 0x0008],
     [0x06, aw88298_reg06(sample_rate)], [0x0C, 0x0064]].map do |reg, val|
      [reg, (val >> 8) & 0xFF, val & 0xFF]
    end
  end

  def initialize(i2c:, i2s:)
    @i2c = i2c
    @i2s = i2s
  end
  attr_reader :i2c, :i2s

  def init_amp(sample_rate)
    self.class.aw88298_init_writes(sample_rate).each do |reg, hi, lo|
      @i2c.write(AW88298_ADDR, reg, hi, lo)
    end
  end

  def play_ulaw(ulaw)
    @i2s.write(self.class.ulaw_decode(ulaw))
  end
end

# ============================================================
# === Tone generators (pure Ruby, no Math dependency) ========
# ============================================================
# Square wave as a little-endian signed-16 PCM string.
def square_pcm(freq_hz, ms, amp, rate)
  total = rate * ms / 1000
  half  = rate / (freq_hz * 2)
  half  = 1 if half < 1
  out = ""
  i = 0
  while i < total
    v = (((i / half) % 2) == 0) ? amp : (-amp)
    v &= 0xFFFF
    out << (v & 0xFF).chr
    out << ((v >> 8) & 0xFF).chr
    i += 1
  end
  out
end

# Square wave as a mu-law byte string. Uses low-amplitude codes
# (0xE7 -> +260, 0x67 -> -260 via G.711 decode) rather than full-scale
# 0x00/0x80 (+/-32124), so the clip is ~42 dB quieter while still exercising the
# full mu-law decode path. (HITL 2026-06-19: full-scale, then +/-1980, both too
# loud — dropped to +/-260.)
def square_ulaw(freq_hz, ms, rate)
  total = rate * ms / 1000
  half  = rate / (freq_hz * 2)
  half  = 1 if half < 1
  out = ""
  i = 0
  while i < total
    out << ((((i / half) % 2) == 0) ? "\xE7" : "\x67")
    i += 1
  end
  out
end

# ============================================================
# === [2] cold-boot init (from app/application.rb) ===========
# ============================================================
I2C_SDA_PIN  = 12
I2C_SCL_PIN  = 11
AXP2101_ADDR = 0x34
AW9523_ADDR  = 0x58
PY32_ADDR    = 0x6F

puts ""
puts "[bringup-i2s] boot"

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

i2c.write(AXP2101_ADDR, 0x97, 0x1C)
i2c.write(AXP2101_ADDR, 0x69, 0x35)
i2c.write(AXP2101_ADDR, 0x30, 0x3F)
i2c.write(AXP2101_ADDR, 0x90, 0xBF)
i2c.write(AXP2101_ADDR, 0x94, 28)
i2c.write(AXP2101_ADDR, 0x95, 28)
i2c.write(AXP2101_ADDR, 0x27, 0x00)
i2c.write(AXP2101_ADDR, 0x99, 24)

i2c.write(AW9523_ADDR, 0x02, 0b00000111)
i2c.write(AW9523_ADDR, 0x03, 0b10000001)
i2c.write(AW9523_ADDR, 0x04, 0b00011000)
i2c.write(AW9523_ADDR, 0x05, 0b00001100)
i2c.write(AW9523_ADDR, 0x11, 0b00010000)
i2c.write(AW9523_ADDR, 0x12, 0b11111111)
i2c.write(AW9523_ADDR, 0x13, 0b11111111)
Machine.delay_ms(20)
i2c.write(AW9523_ADDR, 0x03, 0b10000011)
Machine.delay_ms(10)

# Display is brought up so cold-boot matches application.rb (rails/timing), even
# though this spike does not draw a face.
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

Machine.delay_ms(800)
ver_bytes = i2c.read(PY32_ADDR, 1, 0x02, timeout: 200)
if ver_bytes && ver_bytes.length > 0
  puts sprintf("[bringup-i2s] PY32 REG_VERSION = 0x%02X", ver_bytes.bytes[0])
end

# REQUIRED FOR PY32 COLD-BOOT (see CLAUDE.md / memory): these puts shift the
# bytecode layout enough to avoid a LoadProhibited crash at PY32 init. Keep.
puts "[boot] step:py32-init-begin"
py32 = PY32IOExpander.new(i2c)
puts "[boot] step:py32-instance"
py32.set_direction(0, true)
py32.set_pull_mode(0, true)
py32.digital_write(0, true)
Machine.delay_ms(200)
puts "[boot] step:py32-gpio-enabled"

led_init_attempt = 0
led = nil
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
puts "[boot] step:led-init-ok"

Machine.delay_ms(50)
led.brightness = 100
# GPIO13 probe baseline: LEDs GREEN before any I2S activity.
led.fill(0, 60, 0).show
puts "[boot] step:led-green (pre-I2S)"

# ============================================================
# === Spike A: amp init + I2S tone sweep + mu-law clip =======
# ============================================================
puts "[bringup-i2s] I2C scan check: expecting AW88298 @ 0x36"
# Probe the amp's presence non-destructively (read 1 byte of reg 0x00).
amp_probe = i2c.read(Speaker::AW88298_ADDR, 1, 0x00, timeout: 200)
if amp_probe && amp_probe.length > 0
  puts sprintf("[bringup-i2s] AW88298 @ 0x36 ACK, reg0x00=0x%02X", amp_probe.bytes[0])
else
  puts "[bringup-i2s] WARN AW88298 @ 0x36 no read (scan/wiring suspect)"
end

i2s = I2S.new(sample_rate: SAMPLE_RATE)
spk = Speaker.new(i2c: i2c, i2s: i2s)
spk.init_amp(SAMPLE_RATE)
puts "[bringup-i2s] amp init done; playing tone sweep @ #{SAMPLE_RATE} Hz"

# Descending beep sweep — three distinct tones, ~300 ms each.
# amp 300/32767 (~ -41 dBFS) — HITL 2026-06-19: 8000 then 2000 still too loud.
[880, 660, 440].each do |f|
  i2s.write(square_pcm(f, 300, 300, SAMPLE_RATE))
  Machine.delay_ms(60)
end
puts "[bringup-i2s] tone sweep done; playing mu-law clip"

# Canned mu-law clip: a 440 Hz buzz routed through the real decode path.
spk.play_ulaw(square_ulaw(440, 800, SAMPLE_RATE))
puts "[bringup-i2s] mu-law clip done"

i2s.close

# ============================================================
# === GPIO13 probe verdict: LEDs still controllable? =========
# ============================================================
# Re-color LEDs BLUE after I2S used SoC GPIO13 as DOUT. If they turn blue, the
# WS2812 (PY32) path and I2S DOUT do not contend (spec §7). If LEDs are now
# stuck/garbled, GPIO13 is shared — a 1-way-door design change.
led.fill(0, 0, 60).show
puts "[boot] step:led-blue (post-I2S — LEDs still controllable == no GPIO13 contention)"

puts "[bringup-i2s] DONE — exiting to shell"
