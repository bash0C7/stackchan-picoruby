# app/application.rb — Phase 3 production dispatcher.
#
# Flow:
#   [1] 5s escape hatch (sleep_ms 5000) — crash-loop recovery window
#   [2] cold-boot init (AXP2101 → AW9523 → ILI9342 → PY32 → LED → Face::Neutral)
#   [3] BLE NUS service + Dispatcher + FrameParser + AckSink
#   [4] peri.run — StackChanApp#run, infinite 20 ms tick loop (StackchanApp::LinkLoop)
#
# Upload: rake r2p2:upload_mrb SRC=app/application.rb
# Smoke:  rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'uart'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-protocol'
require 'scservo'
require 'ble'
require 'i2s'

# === StackchanLed (inlined from picoruby-stackchan-led sibling mrbgem) ===
# 12-pixel WS2812 ring driven via PY32IOExpander. Left/right halves
# (LEFT_RANGE / RIGHT_RANGE) each have an Animator for blink/breathing.
class StackchanLed
  PIXEL_COUNT  = 12
  LED_DATA_PIN = 13

  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)

  class Animator
    BLINK_HALF_PERIOD_MS = 500
    BREATHING_LUT = [0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5].freeze
    BREATHING_STEP_MS = 250

    def initialize(led, pixel_range:)
      @led = led
      @pixel_range = pixel_range
      @r = 0
      @g = 0
      @b = 0
      @mode = :off
      @phase_start_ms = nil
    end

    def set(r, g, b, mode)
      @r = r
      @g = g
      @b = b
      @mode = mode
      @phase_start_ms = nil
      @last_applied = nil
      apply_immediately
    end

    # Called every LED_PERIOD_MS by the Ticker. Each apply_color is three PY32
    # I2C transactions (~4 ms) on the bus the touch sensor shares, so only
    # write when the animated colour actually changes.
    def tick(now_ms)
      return unless dynamic?
      @phase_start_ms ||= now_ms
      elapsed = now_ms - @phase_start_ms
      case @mode
      when :blink
        on = (elapsed / BLINK_HALF_PERIOD_MS) % 2 == 0
        apply_color_if_changed(on ? @r : 0, on ? @g : 0, on ? @b : 0)
      when :breathing
        ratio = BREATHING_LUT[(elapsed / BREATHING_STEP_MS) % BREATHING_LUT.size]
        apply_color_if_changed(@r * ratio / 100, @g * ratio / 100, @b * ratio / 100)
      end
    end

    private

    def dynamic?
      @mode == :blink || @mode == :breathing
    end

    def apply_immediately
      case @mode
      when :solid then apply_color(@r, @g, @b)
      when :off   then apply_color(0, 0, 0)
      end
    end

    def apply_color(r, g, b)
      @led.fill_range(@pixel_range.first, @pixel_range.last, r, g, b)
      @led.show
    end

    def apply_color_if_changed(r, g, b)
      rgb = [r, g, b]
      return if @last_applied == rgb
      @last_applied = rgb
      apply_color(r, g, b)
    end
  end

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

  def set_rgb(i, r, g, b)
    @buffer[i] = [r, g, b]
    self
  end

  def fill_range(start_idx, end_idx, r, g, b)
    i = start_idx
    while i <= end_idx
      @buffer[i] = [r, g, b]
      i += 1
    end
    self
  end

  def fill_left(r, g, b)
    fill_range(LEFT_RANGE.first, LEFT_RANGE.last, r, g, b)
  end

  def fill_right(r, g, b)
    fill_range(RIGHT_RANGE.first, RIGHT_RANGE.last, r, g, b)
  end

  def clear
    fill(0, 0, 0)
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

  def animate_side(side, r, g, b, mode)
    case side
    when :both
      left_animator.set(r, g, b, mode)
      right_animator.set(r, g, b, mode)
    when :left
      left_animator.set(r, g, b, mode)
    when :right
      right_animator.set(r, g, b, mode)
    else
      raise ArgumentError, "unknown side: #{side.inspect}"
    end
    self
  end

  # One-shot bright pulse: solid color now, auto-decay to off after duration_ms.
  # Used by Dispatcher#react_to_touch so each tap visibly flashes the zone's
  # LED side regardless of whether the zone changed (same-zone retap still
  # shows an off→on transition because flash_until is overwritten each call).
  def flash_side(side, r, g, b, duration_ms = 300)
    animate_side(side, r, g, b, :solid)
    @flash_until ||= { left: nil, right: nil }
    end_ms = (Machine.uptime_us / 1000) + duration_ms
    case side
    when :both
      @flash_until[:left]  = end_ms
      @flash_until[:right] = end_ms
    when :left
      @flash_until[:left] = end_ms
    when :right
      @flash_until[:right] = end_ms
    end
    self
  end

  def tick(now_ms)
    left_animator.tick(now_ms)
    right_animator.tick(now_ms)
    return unless @flash_until
    if @flash_until[:left] && now_ms >= @flash_until[:left]
      @flash_until[:left] = nil
      animate_side(:left, 0, 0, 0, :off)
    end
    if @flash_until[:right] && now_ms >= @flash_until[:right]
      @flash_until[:right] = nil
      animate_side(:right, 0, 0, 0, :off)
    end
  end

  private

  def left_animator
    @left_animator ||= Animator.new(self, pixel_range: LEFT_RANGE)
  end

  def right_animator
    @right_animator ||= Animator.new(self, pixel_range: RIGHT_RANGE)
  end

  def apply_brightness(r, g, b)
    [r * @brightness / 100, g * @brightness / 100, b * @brightness / 100]
  end

  def clamp(v, lo, hi)
    v < lo ? lo : (v > hi ? hi : v)
  end
end

# === Si12T 3-zone capacitive head-touch driver (inlined, pure Ruby) ===
# I2C 0x68 on the system bus (SDA=12/SCL=11), distinct from the BMI270 IMU at
# 0x69. Reuses the cold-boot I2C instance (injected) — no second bus, no C.
# Register init verified against m5stack/StackChan firmware Si12T.cpp.
# OUTPUT1 (0x10): 2 bits per zone, value 0..3 (NONE/LOW/MID/HIGH).
class Si12T
  ADDR        = 0x68
  REG_CTRL1   = 0x08
  REG_CTRL2   = 0x09
  REG_OUTPUT1 = 0x10
  ENABLE_REGS = (0x0A..0x0F)
  SENS_REGS   = (0x02..0x06)
  ZONE_COUNT  = 3

  def initialize(i2c)
    @i2c          = i2c
    @prev_touched = false
    init_sensor
  end

  def init_sensor
    ENABLE_REGS.each { |r| @i2c.write(ADDR, r, 0x00) }
    @i2c.write(ADDR, REG_CTRL2, 0x0F)   # S/W reset + sleep enable
    @i2c.write(ADDR, REG_CTRL2, 0x07)
    @i2c.write(ADDR, REG_CTRL1, 0x22)   # auto mode, FTC, response 4(2+2)
    SENS_REGS.each { |r| @i2c.write(ADDR, r, 0x33) }  # TYPE_LOW / LEVEL_3
  end

  # [z0, z1, z2] intensities 0..3; [0,0,0] on a failed/empty read.
  def read_zones
    raw  = @i2c.read(ADDR, 1, REG_OUTPUT1)
    byte = raw && raw.bytes[0]
    return [0, 0, 0] unless byte
    z = []
    i = 0
    while i < ZONE_COUNT
      z << ((byte >> (2 * i)) & 0x03)
      i += 1
    end
    z
  end

  # Rising-edge: returns the active zone index ONCE on touch onset (highest
  # intensity; lowest index on a tie), nil while held and until release.
  def poll
    zones   = read_zones
    touched = zones.any? { |v| v > 0 }
    if touched && !@prev_touched
      @prev_touched = true
      best_i = 0
      best_v = -1
      i = 0
      while i < zones.size
        if zones[i] > best_v
          best_v = zones[i]
          best_i = i
        end
        i += 1
      end
      return best_i
    end
    @prev_touched = touched
    nil
  end
end

# StackChan speaker: AW88298 amp (over the system I2C bus) + I2S sample out
# (via the standalone picoruby-i2s gem's I2S class). Pure-Ruby orchestration here;
# only the generic I2S TX is C. mu-law decode + amp-register builder are host-tested.
class Speaker
  ULAW_BIAS    = 0x84
  AW88298_ADDR = 0x36
  # M5Unified rate table for AW88298 reg 0x06 (M5Unified.cpp:_speaker_enabled_cb_cores3).
  AW_RATE_TBL  = [4, 5, 6, 8, 10, 11, 15, 20, 22, 44]

  # ITU G.711: one 8-bit mu-law code -> signed 16-bit linear sample.
  def self.ulaw_byte_to_linear(byte)
    u = (~byte) & 0xFF
    t = ((u & 0x0F) << 3) + ULAW_BIAS
    t = t << ((u & 0x70) >> 4)
    (u & 0x80) != 0 ? (ULAW_BIAS - t) : (t - ULAW_BIAS)
  end

  # Decode a mu-law byte string to a little-endian signed-16 PCM byte string.
  def self.ulaw_decode(ulaw)
    out = ""
    ulaw.each_byte do |b|
      v = ulaw_byte_to_linear(b) & 0xFFFF
      out << (v & 0xFF).chr
      out << ((v >> 8) & 0xFF).chr
    end
    out
  end

  # AW88298 reg 0x06 value for a sample rate (M5Unified formula).
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

  # Ordered AW88298 init writes as [reg, hi, lo] (16-bit big-endian) triples.
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

  # Power/enable the amp over I2C (AW9523 ResetAw88298 hardware reset is done at cold-boot).
  def init_amp(sample_rate)
    self.class.aw88298_init_writes(sample_rate).each do |reg, hi, lo|
      @i2c.write(AW88298_ADDR, reg, hi, lo)
    end
  end

  # Decode a mu-law clip and push it to the I2S TX.
  def play_ulaw(ulaw)
    @i2s.write(self.class.ulaw_decode(ulaw))
  end
end

# [1] 5-second escape hatch. If a previous app.mrb crash-loops the device,
# this window lets a human reach the R2P2 shell and `rm /home/app.mrb` to
# recover. Phase 2 used 2s which was borderline — Phase 3 raises it to 5s.
sleep_ms 5000

# ================================
# === StackchanApp::Face module ==
# ================================
module StackchanApp
  module Face
    # Geometry derived from the M5Stack official StackChan reference photo.
    # Ratios (normalised to screen 320×240):
    #   eye-to-eye   : 0.31 W  = 100 px  (offset ±50 from cx=160)
    #   eye_y        : 0.42 H  = 100 px  (slightly above geometric centre y=120)
    #   mouth_y      : 0.58 H  = 140 px  (slightly below centre, gap 40 from eye)
    #   eye diameter : 0.025 W = 8  px   (radius 4)
    #   mouth width  : 0.16 W  = 50 px   (half-width 25)
    EYE_LEFT_CX  = 110
    EYE_LEFT_CY  = 100
    EYE_RIGHT_CX = 210
    EYE_RIGHT_CY = 100
    EYE_RX       = 4
    EYE_RY       = 4

    EYE_COLOR        = ILI9342::Color::WHITE
    MOUTH_COLOR      = ILI9342::Color::WHITE
    BACKGROUND_COLOR = ILI9342::Color::BLACK

    FACE_REGION_HEIGHT = 200   # rows 0..199; rows 200..239 are the subtitle band

    MOUTH_CX         = 160
    MOUTH_CY         = 140
    MOUTH_HALF_WIDTH = 25

    # Surprised mouth — vertical filled rectangle (open mouth).
    SURPRISED_MOUTH_HALF_W = 6
    SURPRISED_MOUTH_HALF_H = 12

    # Angry brow geometry — V-shaped chevrons above each eye, inner ends drop.
    BROW_OFFSET_Y    = 18   # baseline 18px above eye centerline
    BROW_HALF_LENGTH = 16   # horizontal extent each side of eye cx
    BROW_INNER_DROP  = 8    # inner end of brow drops 8px relative to outer end

    # Bounding boxes of everything a face can paint. Every face sits on the same
    # black field, so changing expression only has to repaint these two bands:
    # refilling all 320x200 pushes ~64000 pixels to move ~5600 of them, and that
    # fill is the bulk of what a face command costs.
    FEATURE_MARGIN = 2
    # Joy raises the mouth corners 18px and Sad drops them 8, while Surprised's
    # open mouth reaches SURPRISED_MOUTH_HALF_H below centre — deeper than Sad.
    MOUTH_MAX_RISE = 18
    EYE_BAND_X   = EYE_LEFT_CX - BROW_HALF_LENGTH - FEATURE_MARGIN
    EYE_BAND_W   = (EYE_RIGHT_CX + BROW_HALF_LENGTH + FEATURE_MARGIN) - EYE_BAND_X
    EYE_BAND_Y   = EYE_LEFT_CY - BROW_OFFSET_Y - FEATURE_MARGIN
    EYE_BAND_H   = (EYE_LEFT_CY + EYE_RY + FEATURE_MARGIN) - EYE_BAND_Y
    MOUTH_BAND_X = MOUTH_CX - MOUTH_HALF_WIDTH - FEATURE_MARGIN
    MOUTH_BAND_W = (MOUTH_CX + MOUTH_HALF_WIDTH + FEATURE_MARGIN) - MOUTH_BAND_X
    MOUTH_BAND_Y = MOUTH_CY - MOUTH_MAX_RISE - FEATURE_MARGIN
    MOUTH_BAND_H = (MOUTH_CY + SURPRISED_MOUTH_HALF_H + FEATURE_MARGIN) - MOUTH_BAND_Y

    # Union of EYE_BAND and MOUTH_BAND — one rectangle `redraw` hands to
    # `batch` as a single panel transaction. Device measurement (BLE face
    # verb, 6 faces x 8 rounds): latency = 0.199s + 0.0051s per panel
    # transaction (R^2 = 0.990), cost per transaction, not per pixel — so
    # merging the eye and mouth clears into one transaction is what pays for
    # itself, not shrinking the pixel count. Computed with min/max rather
    # than assumed, since neither band is reliably the wider or taller one.
    FACE_BAND_X = [EYE_BAND_X, MOUTH_BAND_X].min
    FACE_BAND_Y = [EYE_BAND_Y, MOUTH_BAND_Y].min
    FACE_BAND_W = [EYE_BAND_X + EYE_BAND_W, MOUTH_BAND_X + MOUTH_BAND_W].max - FACE_BAND_X
    FACE_BAND_H = [EYE_BAND_Y + EYE_BAND_H, MOUTH_BAND_Y + MOUTH_BAND_H].max - FACE_BAND_Y


    class Base
      DELTA_Y = 0

      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
      end

      def draw_mouth(display)
        cx = MOUTH_CX
        cy = MOUTH_CY
        hw = MOUTH_HALF_WIDTH
        left_x   = cx - hw
        right_x  = cx + hw
        corner_y = cy - self.class::DELTA_Y
        display.draw_line(left_x, corner_y, cx,      cy,       MOUTH_COLOR)
        display.draw_line(cx,     cy,       right_x, corner_y, MOUTH_COLOR)
      end

      # Full repaint. Used at cold boot, when nothing is known about what is
      # already on the panel.
      def draw(display)
        display.draw_rect(0, 0, 320, FACE_REGION_HEIGHT, BACKGROUND_COLOR, fill: true)
        draw_features(display)
      end

      # What this face paints on top of the black field. Subclasses extend this
      # rather than `draw`, so the full and differential paths stay in step.
      def draw_features(display)
        draw_eyes(display)
        draw_mouth(display)
      end

      # Repaint over a panel that already shows a face: batch the union band
      # (FACE_BAND_*) into one panel transaction instead of the two separate
      # clear-then-draw transactions the eye and mouth bands used to cost.
      # The batch buffer starts pre-filled with BACKGROUND_COLOR, so no
      # explicit clear is needed before painting into it. Same result as
      # `draw` when a face is already on screen, at about a tenth of the
      # pixels and a fraction of the transactions.
      def redraw(display)
        display.batch(FACE_BAND_X, FACE_BAND_Y, FACE_BAND_W, FACE_BAND_H, BACKGROUND_COLOR) { draw_features(display) }
      end

      # Update only the eye region (blink restore), keeping the mouth and
      # overall background untouched. Batches into one transaction instead of
      # the old clear_eye_region + draw_eyes pair (see BLINK_BAND_* for why
      # that pair was expensive).
      def redraw_eyes_open(display)
        display.batch(BLINK_BAND_X, BLINK_BAND_Y, BLINK_BAND_W, BLINK_BAND_H, BACKGROUND_COLOR) { draw_eyes(display) }
      end

      # Eye-only update that closes the eyes (horizontal line), used for blink
      # animation. Mirrors redraw_eyes_open but draws closed-eye geometry;
      # mouth and overall background outside BLINK_BAND stay untouched.
      def redraw_eyes_closed(display)
        display.batch(BLINK_BAND_X, BLINK_BAND_Y, BLINK_BAND_W, BLINK_BAND_H, BACKGROUND_COLOR) do
          display.draw_line(
            EYE_LEFT_CX - CLOSED_EYE_HALF_W, EYE_LEFT_CY,
            EYE_LEFT_CX + CLOSED_EYE_HALF_W, EYE_LEFT_CY,
            EYE_COLOR
          )
          display.draw_line(
            EYE_RIGHT_CX - CLOSED_EYE_HALF_W, EYE_RIGHT_CY,
            EYE_RIGHT_CX + CLOSED_EYE_HALF_W, EYE_RIGHT_CY,
            EYE_COLOR
          )
        end
      end
    end

    class Neutral < Base
      DELTA_Y = 0
    end

    class Smile < Base
      DELTA_Y = 8
    end

    class Joy < Base
      DELTA_Y = 18
    end

    class Sad < Base
      DELTA_Y = -8
    end

    class Angry < Base
      DELTA_Y = 0   # neutral mouth

      def draw_features(display)
        super
        # Left brow: outer end up, inner end down (V-slant toward bridge of nose).
        display.draw_line(
          EYE_LEFT_CX - BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y,
          EYE_LEFT_CX + BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_COLOR
        )
        # Right brow: mirror — inner end down, outer end up.
        display.draw_line(
          EYE_RIGHT_CX - BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_RIGHT_CX + BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y,
          EYE_COLOR
        )
      end
    end

    class Surprised < Base
      def draw_mouth(display)
        display.draw_rect(
          MOUTH_CX - SURPRISED_MOUTH_HALF_W,
          MOUTH_CY - SURPRISED_MOUTH_HALF_H,
          SURPRISED_MOUTH_HALF_W * 2,
          SURPRISED_MOUTH_HALF_H * 2,
          MOUTH_COLOR,
          fill: true
        )
      end
    end

    # Eye-region bounding box for eye-only updates (blink animation).
    # Large enough to cover both the open ellipse (EYE_RX/RY) and the closed
    # horizontal line (CLOSED_EYE_HALF_W), so clearing this region wipes
    # either shape cleanly.
    EYE_REGION_HALF_W = 6
    EYE_REGION_HALF_H = 6

    # Union of both eyes' regions — the single rectangle redraw_eyes_open and
    # redraw_eyes_closed hand to `batch`. Driving the real driver with a
    # counting SPI measured redraw_eyes_open at 180 SPI#write calls (two rect
    # clears plus two filled ellipses, each a 14-span fill) and
    # redraw_eyes_closed at 24; at 0.85ms per call (R^2 = 0.991) that is
    # 153ms to reopen the eyes and 20ms to close them. Reopening alone runs
    # almost as long as BLINK_CLOSED_MS (150) itself, so a blink lasted
    # roughly twice its configured duration and the run loop stalled ~173ms
    # every 5s. Computed with min/max rather than assumed, since neither eye
    # is reliably the leftmost and they need not share a centre line.
    BLINK_BAND_X = [EYE_LEFT_CX - EYE_REGION_HALF_W, EYE_RIGHT_CX - EYE_REGION_HALF_W].min
    BLINK_BAND_Y = [EYE_LEFT_CY - EYE_REGION_HALF_H, EYE_RIGHT_CY - EYE_REGION_HALF_H].min
    BLINK_BAND_W = [EYE_LEFT_CX + EYE_REGION_HALF_W, EYE_RIGHT_CX + EYE_REGION_HALF_W].max - BLINK_BAND_X
    BLINK_BAND_H = [EYE_LEFT_CY + EYE_REGION_HALF_H, EYE_RIGHT_CY + EYE_REGION_HALF_H].max - BLINK_BAND_Y

    # Closed eye for blink animation. Draws a short horizontal line where
    # the eye normally sits, giving the impression of a closed lid.
    CLOSED_EYE_HALF_W = 4

    class Closed < Base
      def draw_eyes(display)
        display.draw_line(
          EYE_LEFT_CX - CLOSED_EYE_HALF_W, EYE_LEFT_CY,
          EYE_LEFT_CX + CLOSED_EYE_HALF_W, EYE_LEFT_CY,
          EYE_COLOR
        )
        display.draw_line(
          EYE_RIGHT_CX - CLOSED_EYE_HALF_W, EYE_RIGHT_CY,
          EYE_RIGHT_CX + CLOSED_EYE_HALF_W, EYE_RIGHT_CY,
          EYE_COLOR
        )
      end

      # Closed eyes only, no mouth — the torque-off idle face is intentionally
      # mouthless. For blink animation use Base#redraw_eyes_closed instead
      # (eye-only, no flicker).
      def draw_features(display)
        draw_eyes(display)
      end
    end
  end

  class Head
    # Raw servo position range per axis for 90° from forward, measured via
    # the 5-pose HITL calibration (stackchan-ble-control calibrate, 2026-05-25).
    # YAW_RANGE_RAW=300 → 90° = 300 raw units (≈0.3°/unit at head output):
    #   forward=482, LEFT MAX(90°)=182 (-300), RIGHT MAX(90°)=783 (+301).
    # PITCH_RANGE_RAW=296 → 90° up = 296 raw units; pitch-down not supported:
    #   forward=633, UP MAX(90°)=929 (+296).
    YAW_RANGE_RAW   = 300
    PITCH_RANGE_RAW = 296

    # Forward (zero) positions measured by HITL calibration 2026-05-25.
    # Supersede the old factory-firmware guess (460/620): operator aligned
    # the head to forward by hand, then read raw servo position.
    SERVO_YAW_ZERO   = 482
    SERVO_PITCH_ZERO = 633

    def initialize(yaw_servo, pitch_servo)
      @yaw   = yaw_servo
      @pitch = pitch_servo
    end

    # Apply pre-computed raw positions. Dispatcher does the YL/YR/PU →
    # signed raw conversion; Head only writes what it's told.
    def apply(yaw_raw: nil, pitch_raw: nil, time_ms: 0, velocity: 0)
      @yaw.write_pos(yaw_raw, time_ms: time_ms, speed: velocity)     if yaw_raw
      @pitch.write_pos(pitch_raw, time_ms: time_ms, speed: velocity) if pitch_raw
    end

    # Enable/disable torque on both servos. No-op for absent servos.
    def enable_torque(on)
      @yaw.enable_torque(on)   if @yaw
      @pitch.enable_torque(on) if @pitch
    end

    # Returns raw positions keyed by axis. nil for missing/unreachable servos.
    # Note: symbol keys. Dispatcher's emit_servo_detail rewrite (Task 11) will
    # read these symbol keys; the old string-keyed format ("Y_actual" /
    # "P_actual") is removed.
    def read_actual
      { yaw: (@yaw && @yaw.read_pos), pitch: (@pitch && @pitch.read_pos) }
    end

    # Cold-boot bring-up self-test: nudge yaw ±10 raw and return to center.
    # Unchanged from Task 9 — copied here as part of the Head class rewrite.
    def selftest
      return false if @yaw.nil?
      y0 = SERVO_YAW_ZERO
      [(y0 + 10), (y0 - 10), y0].each do |target|
        @yaw.write_pos(target, time_ms: 50, speed: 0)
        Machine.delay_ms(80)
      end
      true
    end
  end
end

# ====================================
# === StackchanApp::Dispatcher class ==
# ====================================
module StackchanApp
  class Dispatcher
    ERROR_FRAME = "?\n"
    ACK_FRAME   = ".\n"

    FACE_TABLE = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
      "3" => Face::Surprised,
      "4" => Face::Sad,
      "5" => Face::Angry,
    }.freeze

    # Touch zone → face for immediate on-device feedback (no PC round-trip).
    # Used by StackChanApp's heartbeat touch-poll; this Dispatcher draws the
    # face directly on the LCD the instant Si12T fires a rising edge.
    TOUCH_FACE_TABLE = {
      0 => Face::Surprised,
      1 => Face::Angry,
      2 => Face::Sad,
    }.freeze

    # Touch zone → LED [side, r, g, b]. Each tap flashes the zone-coded side
    # in a zone-coded color so the human can identify which zone fired by
    # color/position. Side is :both/:left/:right matching StackchanLed; color
    # values are 0..255 raw (no brightness scaling beyond @brightness).
    TOUCH_LED_TABLE = {
      0 => [:both,  0, 60, 0],
      1 => [:right, 60, 0, 0],
      2 => [:left,  0, 0, 60],
    }.freeze

    MODE_TABLE = {
      "s" => :solid,
      "b" => :blink,
      "p" => :breathing,
      "o" => :off,
    }.freeze

    SIDE_TABLE = {
      "L" => :left,
      "R" => :right,
      "B" => :both,
    }.freeze

    # Bottom subtitle band: rows SUBTITLE_BAND_Y..239 of the 320x240 panel.
    SUBTITLE_BAND_Y      = 200
    SUBTITLE_BAND_HEIGHT = 40
    SUBTITLE_FONT        = "go16"   # JIS X 0208 16px gothic
    SUBTITLE_TEXT_Y      = 212      # vertical centering of the 16px glyph in the band
    SUBTITLE_MARGIN_X    = 4
    SUBTITLE_MAX_CHARS   = 19       # (320 - 2*4) / 16px per JIS glyph
    SUBTITLE_FG          = ILI9342::Color::WHITE
    SUBTITLE_BG          = ILI9342::Color::BLACK

    attr_reader :current_face_class

    def initialize(display:, led:, stdout: $stdout, head: nil)
      @display = display
      @led     = led
      @stdout  = stdout
      @head    = head
      @current_face_class = Face::Neutral
    end

    def handle(frame)
      # Legacy raw Y/P keys are retired (2026-05-21 direction-key migration).
      # Reject outright so old PC clients see the migration via ERROR ACK
      # rather than getting silently dropped.
      if frame.key?("Y") || frame.key?("P")
        @stdout.write(ERROR_FRAME)
        return
      end
      return handle_torque(frame)   if frame.key?("torque")
      return handle_selftest(frame) if frame.key?("selftest")
      return handle_read_pos(frame)  if frame.key?("read")

      attempts = []
      attempts << handle_face(frame) if frame.key?("F")
      attempts << handle_led(frame)  if frame.key?("L")
      attempts << handle_text(frame) if frame.key?("text")
      servo_present = frame.key?("YL") || frame.key?("YR") || frame.key?("PU")
      if servo_present
        success = handle_head(frame)
        @stdout.write(success ? ACK_FRAME : ERROR_FRAME)
        emit_servo_detail(frame) if success
      else
        success = attempts.empty? || attempts.all? { |ok| ok }
        @stdout.write(success ? ACK_FRAME : ERROR_FRAME)
      end
    rescue => e
      log_error(e)
      @stdout.write(ERROR_FRAME)
    end

    # Called from StackChanApp's heartbeat right after the touch sensor
    # fires a rising edge. Picks a face by zone, draws it immediately, and
    # updates current_face_class so the next blink redraw uses it. The
    # whole path is local SPI to the LCD — no BLE round-trip, no PC.
    def react_to_touch(zone)
      face_class = TOUCH_FACE_TABLE[zone] || Face::Surprised
      @current_face_class = face_class
      face_class.new.redraw(@display)
      led_entry = TOUCH_LED_TABLE[zone]
      if @led && led_entry
        side, r, g, b = led_entry
        @led.flash_side(side, r, g, b)
      end
    end

    private

    def handle_face(frame)
      face_class = FACE_TABLE[frame["F"]]
      return false unless face_class
      @current_face_class = face_class
      face_class.new.redraw(@display)
      true
    end

    def handle_text(frame)
      text = frame["text"]
      return false unless text
      text = text[0, SUBTITLE_MAX_CHARS]
      # Clear the band, then draw. draw_rect args: (x, y, w, h, color, fill:)
      @display.draw_rect(0, SUBTITLE_BAND_Y, 320, SUBTITLE_BAND_HEIGHT,
                         SUBTITLE_BG, fill: true)
      @display.draw_text(SUBTITLE_MARGIN_X, SUBTITLE_TEXT_Y, text,
                         font: SUBTITLE_FONT, fg: SUBTITLE_FG, bg: SUBTITLE_BG)
      true
    end

    def handle_torque(frame)
      case frame["torque"]
      when "on"
        @head.enable_torque(true) if @head
        @current_face_class = Face::Neutral
        Face::Neutral.new.redraw(@display)
        @stdout.write(ACK_FRAME)
      when "off"
        @head.enable_torque(false) if @head
        @current_face_class = Face::Closed
        Face::Closed.new.redraw(@display)
        @stdout.write(ACK_FRAME)
      else
        @stdout.write(ERROR_FRAME)
      end
    end

    def handle_selftest(frame)
      unless frame["selftest"] == "run"
        @stdout.write(ERROR_FRAME)
        return
      end
      if @head.nil?
        @stdout.write(ERROR_FRAME)
        return
      end
      @head.selftest
      @stdout.write(ACK_FRAME)
      emit_servo_detail({ "YL" => "0", "PU" => "0" })  # synthetic frame: report current actuals
    end

    def handle_read_pos(frame)
      unless frame["read"] == "pos"
        @stdout.write(ERROR_FRAME)
        return
      end
      if @head.nil?
        @stdout.write(ERROR_FRAME)
        return
      end
      @stdout.write(ACK_FRAME)
      actual = @head.read_actual
      yaw_raw   = actual[:yaw]
      pitch_raw = actual[:pitch]
      yaw_part   = yaw_raw.nil?   ? "yaw_raw:unknown"   : "yaw_raw:#{yaw_raw}"
      pitch_part = pitch_raw.nil? ? "pitch_raw:unknown" : "pitch_raw:#{pitch_raw}"
      @stdout.write("<#{yaw_part},#{pitch_part}>\n")
    end

    def handle_led(frame)
      mode = MODE_TABLE[frame["M"]]
      return false unless mode
      side = SIDE_TABLE[frame["S"]]
      return false unless side
      r = (frame["R"] || "0").to_i
      g = (frame["G"] || "0").to_i
      b = (frame["B"] || "0").to_i
      @led.animate_side(side, r, g, b, mode)
      true
    end

    def handle_head(frame)
      yaw_raw   = nil
      pitch_raw = nil

      # Direction confirmed by HITL 2026-05-25: raw BELOW the forward zero is
      # StackChan's left (cal LEFT MAX = 182), raw ABOVE is its right
      # (RIGHT MAX = 783). So YL ("StackChan's left") subtracts, YR adds.
      if frame.key?("YL")
        mag = frame["YL"].to_i
        return false unless mag >= 0 && mag <= 100
        yaw_raw = Head::SERVO_YAW_ZERO - (mag * Head::YAW_RANGE_RAW / 100)
      elsif frame.key?("YR")
        mag = frame["YR"].to_i
        return false unless mag >= 0 && mag <= 100
        yaw_raw = Head::SERVO_YAW_ZERO + (mag * Head::YAW_RANGE_RAW / 100)
      end

      if frame.key?("PU")
        mag = frame["PU"].to_i
        return false unless mag >= 0 && mag <= 100
        pitch_raw = Head::SERVO_PITCH_ZERO + (mag * Head::PITCH_RANGE_RAW / 100)
      end

      return false unless yaw_raw || pitch_raw
      return true if @head.nil?
      @head.apply(
        yaw_raw:   yaw_raw,
        pitch_raw: pitch_raw,
        time_ms:   (frame["T"] || "0").to_i,
        velocity:  (frame["V"] || "0").to_i,
      )
      true
    end

    # Reports the pose AT COMMAND RECEIPT, not after the move: handle calls
    # @head.apply (which only commands the move) and lands here immediately, so
    # a <T:600> command reads the servo while it is still leaving the old pose.
    # Deliberate (2026-08-31): waiting out T before answering would delay the
    # ACK by T and stall LinkLoop for that long, rebuilding the latency Phase 1
    # removed. The detail's operational job is the `unknown` signal (operator
    # calibration needed), which does not depend on when the read happens; a
    # post-move pose comes from a separate <read:pos> once the move is done.
    def emit_servo_detail(_frame)
      if @head.nil?
        @stdout.write("<YL_actual:unknown,PU_actual:unknown>\n")
        return
      end
      actual = @head.read_actual
      yaw_raw   = actual[:yaw]
      pitch_raw = actual[:pitch]

      yaw_part = if yaw_raw.nil?
        "YL_actual:unknown"
      else
        # Mirror handle_head: above the zero is StackChan's right (YR),
        # below is its left (YL).
        delta = yaw_raw - Head::SERVO_YAW_ZERO
        if delta >= 0
          mag = delta * 100 / Head::YAW_RANGE_RAW
          "YR_actual:#{mag}"
        else
          mag = (-delta) * 100 / Head::YAW_RANGE_RAW
          "YL_actual:#{mag}"
        end
      end

      pitch_part = if pitch_raw.nil?
        "PU_actual:unknown"
      else
        delta = pitch_raw - Head::SERVO_PITCH_ZERO
        mag = delta >= 0 ? (delta * 100 / Head::PITCH_RANGE_RAW) : 0
        "PU_actual:#{mag}"
      end

      @stdout.write("<#{yaw_part},#{pitch_part}>\n")
    end

    def log_error(e)
      # No-op for now; on-device logging would go here.
    end
  end
end

# ==========================================
# === StackchanApp::AudioReceiver class ====
# ==========================================
module StackchanApp
  # Mac->device lo-fi audio receiver — half-duplex phase-separated design.
  #
  # On <A:N>: sends <A:ready> via notify_fn, blocks main_task for T ms via
  # delay_fn (defaults to Machine.delay_ms), then drains all accumulated BLE
  # bytes from drain_fn and plays them. Non-audio frames are yielded to the block.
  #
  # T = n*1000/8000 + 3000ms  (BLE throughput ~8KB/s + margin; see
  # receive_t_ms below for the exact breakdown). T covers only the pre-play
  # wait (announce settle + blast + margin) -- the subsequent I2S playback
  # itself takes a further ~n*1000/8000 ms, which callers waiting on the PC
  # side must budget for separately (see Stackchan::Voice::Streamer /
  # pc/stackchan-pico's stream_audio).
  # delay_fn/notify_fn/drain_fn are injectable for picotest.
  class AudioReceiver
    # 200ms of silence overwrites all I2S DMA circular descriptors so the last
    # audio frame does not replay at EOF.
    SILENCE_TAIL = ("\x00" * 3200)

    # The wait for a clip is split into steps of this length. The ESP32 port
    # holds inbound writes in a bounded queue and only hands them to Ruby while
    # the BLE poll runs, so waiting out a whole clip in one call overflows it:
    # measured on hardware as "write queue full (depth=32), dropping" during a
    # 27KB clip, which silently loses audio the peer already sent. 50ms holds
    # ~400 bytes at the ~8KB/s this link sustains -- two of the port's slots.
    DRAIN_STEP_MS = 50

    def initialize(speaker:, parser:, delay_fn: nil)
      @speaker  = speaker
      @parser   = parser
      @delay_fn = delay_fn
    end

    # Consume one RX chunk. Returns 1 if a clip was played, 0 otherwise.
    # Non-audio frames are yielded to the block.
    def consume(rx_data, notify_fn: nil, drain_fn: nil, pump_fn: nil)
      @parser.feed(rx_data).each do |frame|
        if frame.key?("A")
          n = frame["A"].to_i
          next if @speaker.nil? || n <= 0
          notify_fn.call("<A:ready>\n") if notify_fn
          ulaw = wait_and_drain(receive_t_ms(n), drain_fn, pump_fn)
          play(ulaw)
          return 1
        else
          yield frame if block_given?
        end
      end
      0
    end

    private

    def receive_t_ms(n)
      # T must cover: PC READY_WAIT_S (1500ms) + blast time (n/8000s) + margin (1500ms).
      # 3000ms base gives 1500ms after blast even if BLE throughput dips to ~6KB/s.
      (n * 1000 / 8000) + 3000
    end

    # Wait out t ms in DRAIN_STEP_MS steps, pumping the BLE port and collecting
    # everything it hands over on each step. Splitting the wait is what keeps
    # the port's inbound queue from overflowing; see DRAIN_STEP_MS.
    def wait_and_drain(t, drain_fn, pump_fn)
      buf = ""
      waited = 0
      while waited < t
        step = t - waited
        step = DRAIN_STEP_MS if step > DRAIN_STEP_MS
        if @delay_fn
          @delay_fn.call(step)
        else
          Machine.delay_ms(step)
        end
        waited += step
        pump_fn.call if pump_fn
        next unless drain_fn
        while (chunk = drain_fn.call)
          buf << chunk
        end
      end
      buf
    end

    def play(ulaw)
      return if ulaw.bytesize == 0
      @speaker.play_ulaw(ulaw)
      @speaker.i2s.write(SILENCE_TAIL) if @speaker.i2s
    end
  end
end

module StackchanApp
  # Periodic work that used to ride on the 1 s BLE heartbeat: head-touch poll,
  # LED animation, liveness blink. Pure: the caller passes now_ms, nothing here
  # reads Machine or sleeps, so the run loop never stalls on it.
  class Ticker
    TOUCH_PERIOD_MS = 50
    LED_PERIOD_MS   = 50
    BLINK_PERIOD_MS = 5000
    BLINK_CLOSED_MS = 150

    def initialize(display:, led:, touch:, dispatcher:, notify:)
      @display    = display
      @led        = led
      @touch      = touch
      @dispatcher = dispatcher
      @notify     = notify
      @touch_at   = nil
      @led_at     = nil
      @blink_at   = nil
      @closed_at  = nil
    end

    def tick(now_ms)
      if due?(@touch_at, now_ms, TOUCH_PERIOD_MS)
        @touch_at = now_ms
        poll_touch
      end
      if due?(@led_at, now_ms, LED_PERIOD_MS)
        @led_at = now_ms
        @led.tick(now_ms)
      end
      blink(now_ms)
    end

    private

    def due?(last, now_ms, period)
      last.nil? || now_ms - last >= period
    end

    # Rising edge -> immediate on-device face/LED reaction, then one
    # <touch:N> for the PC (meaningful only while a central is subscribed;
    # the notify sink drops it otherwise).
    def poll_touch
      return unless @touch
      zone = @touch.poll
      return unless zone
      @dispatcher.react_to_touch(zone)
      @notify.call("<touch:#{zone}>\n")
    rescue => e
      puts "[application] touch poll error: #{e.class}: #{e.message}"
    end

    # Liveness blink: eyes closed for BLINK_CLOSED_MS every BLINK_PERIOD_MS,
    # as a two-state machine so the loop keeps serving BLE while closed.
    def blink(now_ms)
      @blink_at ||= now_ms
      if @closed_at
        if now_ms - @closed_at >= BLINK_CLOSED_MS
          @dispatcher.current_face_class.new.redraw_eyes_open(@display)
          @closed_at = nil
        end
      elsif now_ms - @blink_at >= BLINK_PERIOD_MS
        @dispatcher.current_face_class.new.redraw_eyes_closed(@display)
        @blink_at  = now_ms
        @closed_at = now_ms
      end
    end
  end

  # One tick of the BLE peripheral's run loop, plus the notify gate. BLE is
  # reached only through `port`, so this runs on the host picotest VM.
  #
  # Why event_popped on EVERY tick: on the ESP32 port, NimBLE's host task only
  # fills ring buffers; inbound writes and events reach Ruby exclusively inside
  # BLE#_event_popped. BLE#start calls that only after the queue already
  # yielded an event, and the only thing that wakes the queue on its own is
  # the 1 s heartbeat — that was the 1 s command latency. This loop wakes on
  # its own every TICK_MS and drains regardless.
  class LinkLoop
    TICK_MS = 20   # ESP32 VM tick is 10 ms: a pop with no event returns after 2 ticks

    # port: pop_event(timeout_ms:) / event_popped / take_write(handle) / send_notification(handle, frame)
    def initialize(port:, rx_handle:, tx_handle:, cccd_handle:, ticker:, on_packet:, on_rx:, clock:, log:)
      @port        = port
      @rx_handle   = rx_handle
      @tx_handle   = tx_handle
      @cccd_handle = cccd_handle
      @ticker      = ticker
      @on_packet   = on_packet
      @on_rx       = on_rx
      @clock       = clock
      @log         = log
      @notify_enabled = false
      @rx_at = nil
    end

    def notify_enabled?
      @notify_enabled
    end

    def tick
      event = @port.pop_event(timeout_ms: TICK_MS)
      @port.event_popped
      @on_packet.call(event) if event.is_a?(String)
      poll_cccd      # before drain_rx: a subscribe landing with the first command must not lose its ACK
      drain_rx
      @ticker.tick(@clock.call / 1000)
    end

    # Non-blocking variant for callers already waiting on something else
    # (AudioReceiver's pump_fn): keeps the port's queues moving.
    def pump
      @port.event_popped
      event = @port.pop_event(timeout_ms: 0)
      @on_packet.call(event) if event.is_a?(String)
      event
    end

    # AckSink: one complete newline-terminated frame. Sent immediately; dropped
    # while no central is subscribed (the PC subscribes before its first write).
    def write(frame)
      unless @notify_enabled
        @rx_at = nil   # nothing answers this command; never stamp a later one against it
        return
      end
      @port.send_notification(@tx_handle, frame)
      stamp_ack
    end

    def disconnected
      @notify_enabled = false
      @rx_at = nil
    end

    private

    def poll_cccd
      cccd = @port.take_write(@cccd_handle)
      return unless cccd
      @notify_enabled = (cccd == "\x01\x00")
      @log.call("[application] notify #{@notify_enabled ? 'enabled' : 'disabled'}")
    end

    def drain_rx
      data = @port.take_write(@rx_handle)
      while data
        @rx_at = @clock.call
        @on_rx.call(data)
        data = @port.take_write(@rx_handle)
      end
    end

    # One line per command: the first notification after an RX chunk carries
    # the rx->ack delta in microseconds (the device-side latency component).
    def stamp_ack
      return unless @rx_at
      ack_at = @clock.call
      @log.call("[t] rx=#{@rx_at} ack=#{ack_at} d=#{ack_at - @rx_at}")
      @rx_at = nil
    end
  end
end

# [2] cold-boot init — pinch-perfect copy of app.rb's init block (Phase 2
# bring-up smoke v13-aw9523-p0). Order is critical; see CLAUDE.md
# "CoreS3 cold-boot 初期化シーケンス" section for the why behind each I2C write.
I2C_SDA_PIN  = 12
I2C_SCL_PIN  = 11
AXP2101_ADDR = 0x34
AW9523_ADDR  = 0x58
PY32_ADDR    = 0x6F

puts ""
puts "[application] boot"

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

i2c.write(AXP2101_ADDR, 0x97, 0x1C)
i2c.write(AXP2101_ADDR, 0x69, 0x35)
i2c.write(AXP2101_ADDR, 0x30, 0x3F)
i2c.write(AXP2101_ADDR, 0x90, 0xBF)
i2c.write(AXP2101_ADDR, 0x92, 13)   # ALDO1 = 1.8V — AW88298 speaker amp rail (M5Unified Power_Class.cpp:167)
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
  puts sprintf("[application] PY32 REG_VERSION = 0x%02X", ver_bytes.bytes[0])
end

# NOTE: The puts statements in this block are REQUIRED to prevent a
# LoadProhibited crash at PY32 init region. See memory entry
# `project-py32-init-puts-required` — empirically each puts shifts the
# crash position one line later; with 5 puts the boot completes. Treat
# these as production boot markers, NOT removable debug logs.
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
led.show
led.brightness = 100
puts "[boot] step:led-show-ok"
StackchanApp::Face::Closed.new.draw(display)
puts "[application] LCD cold-boot done (torque-OFF idle)"
# Si12T head-touch — reuse the already-open system I2C instance (no 2nd bus).
# Low-risk per spec; failure must not block face/LED/BLE, so keep @touch=nil.
@touch = nil
begin
  @touch = Si12T.new(i2c)
  puts "[boot] step:si12t-init-ok"
rescue => e
  puts "[boot] si12t init failed: #{e.class}: #{e.message}"
end

# Servo bring-up — torque is intentionally left OFF so the operator can
# physically align the head before sending <torque:on>. Failure must NOT
# block face/LED — keep @head=nil so Dispatcher can emit the "unknown"
# detail signal while Phase A features stay live.
@head = nil
begin
  # Pin mapping: per StackChan/firmware/main/hal/hal_servo.cpp:169
  #   _scs_bus.begin(UART_NUM_1, 1000000, /*tx_pin=*/6, /*rx_pin=*/7)
  # so the ESP32 transmits on GPIO 6 (to the servo bus' RX) and receives on
  # GPIO 7 (from the servo bus' TX). Earlier picoruby app had these swapped,
  # which produced perfectly silent RX (no echo, no servo response).
  servo_uart = UART.new(unit: :ESP32_UART1, txd_pin: 6, rxd_pin: 7, baudrate: 1_000_000)
  yaw_servo   = SCServo.new(servo_uart, id: 1)
  pitch_servo = SCServo.new(servo_uart, id: 2)
  # SCS EEPROM default is torque ON, so we must explicitly disable to honor
  # the cold-boot torque-OFF design (operator physically aligns then sends
  # <torque:on>). Plan §Task 14 assumed default-OFF — Task 15 HITL revealed
  # the EEPROM-default state.
  yaw_servo.enable_torque(false)
  pitch_servo.enable_torque(false)
  @head = StackchanApp::Head.new(yaw_servo, pitch_servo)
  puts "[boot] servo init OK (torque OFF, awaiting <torque:on>)"
rescue => e
  puts "[boot] servo init failed: #{e.class}: #{e.message}"
end

# Diagnostic: bypass SCServo wrapper, send raw SCS PING packets via UART
# and hex-dump whatever bytes arrive on RX. Purpose: distinguish
#   (a) servo UART TX dead          -> raw=<empty>
#   (b) half-duplex echo            -> raw begins FF FF <id> 02 01 <~cksum>
#                                       (= the PING packet we just sent)
#   (c) servo responds correctly    -> raw begins FF FF <id> 02 00 <~cksum>
#                                       (= status packet ERR=0)
#   (d) wrong baud / framing        -> raw is garbage with no FF FF
if servo_uart
  [1, 2].each do |servo_id|
    servo_uart.clear_rx_buffer
    sum = servo_id + 2 + 1
    cksum = (~sum) & 0xFF
    pkt = [0xFF, 0xFF, servo_id, 2, 1, cksum]
    servo_uart.write(pkt.pack('C*'))
    servo_uart.flush
    Machine.delay_ms(80)
    raw = servo_uart.readpartial(64)
    if raw && !raw.empty?
      hex = ""
      raw.bytes.each { |b| hex << sprintf("%02X ", b) }
      puts "[diag id=#{servo_id}] PING tx=FF FF #{sprintf("%02X", servo_id)} 02 01 #{sprintf("%02X", cksum)} raw_rx=#{hex.strip}"
    else
      puts "[diag id=#{servo_id}] PING raw_rx=<empty>"
    end
  end
end

# Diagnostic: capture raw RX bytes from a single read_pos request so we can
# analyze why read_pos returns nil. Expected layouts:
#   echo only        : raw begins FF FF <id> 04 38 02 <cksum> ...  (= our READ pkt)
#   no echo, response: raw begins FF FF <id> 04 00 <pos_l> <pos_h> <cksum>
#   wrong register   : response uses different LEN / data byte count
#   silent failure   : raw=<empty>
if @head
  [yaw_servo, pitch_servo].each do |s|
    sid = s.instance_variable_get(:@id)
    puts "[diag read_pos_raw id=#{sid}] #{s.read_pos_raw_debug}"
  end
end

# Speaker — AW88298 amp (system I2C bus) + I2S TX @ 8 kHz (picoruby-i2s, SoC
# GPIO13 DOUT; Spike A proved no WS2812 contention). Audio is decoration, so a
# failure must NOT block face/LED/BLE — keep @speaker=nil and the app stays live.
SPEAKER_SAMPLE_RATE = 8000
@speaker = nil
begin
  speaker_i2s = I2S.new(sample_rate: SPEAKER_SAMPLE_RATE)
  @speaker = Speaker.new(i2c: i2c, i2s: speaker_i2s)
  @speaker.init_amp(SPEAKER_SAMPLE_RATE)
  puts "[boot] speaker init OK (AW88298 @ 0x36 + I2S @ #{SPEAKER_SAMPLE_RATE}Hz)"
rescue => e
  puts "[boot] speaker init failed: #{e.class}: #{e.message}"
end

# Cold-boot self-test removed 2026-05-21 — protocol now exposes
# <selftest:run> for on-demand UART round-trip check, and the cold-boot
# face/servo state (Face::Closed + torque OFF) is itself the idle indicator
# that operators read for "alive vs. wedged" at a glance.

# cold-boot block (AXP2101/AW9523/SPI/ILI9342/PY32/LED/Face::Closed.draw) は
# 同期 I2C/SPI op で CPU を占有し、BTstack run_loop の FreeRTOS task を starve させる。
# yield せず BLE.new に入ると gap_advertisements_enable(1) は呼ばれても RF emit
# されない (silent fail、device-side log だけ HCI WORKING 出る)。
# sleep_ms で control を yield して BTstack task に initialization を完了させる。
# 2026-05-17 bisect: cold-boot 削除 variant HIT / cold-boot + sleep_ms 3000 variant HIT / sleep 無し MISS。
sleep_ms 3000

# [3] BLE NUS service. UUID / property masks copied from Phase 2 ble_smoke.rb
# (deleted in this Phase 3 PR; structure lives in application.rb now).
#
# Thin adapter: GATT database, advertising, the four `port` methods LinkLoop
# needs, and the run loop. All per-tick logic (drain order, notify gate, ACK
# stamps) is in StackchanApp::LinkLoop; periodic work is in StackchanApp::Ticker.
# Both are host-tested; only what is left here needs the device.
class StackChanApp < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
  AD_FLAGS = 0x06
  BTSTACK_EVENT_STATE = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05

  NUS_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  NUS_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  NUS_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x03\x00\x40\x6e"

  NUS_RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
  NUS_TX_PROPS = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
  NUS_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
  NUS_CCCD_PROPS = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize(display:, led:, head: nil, touch: nil, speaker: nil)
    @display = display
    @led     = led
    @head    = head
    @touch   = touch
    @speaker = speaker
    @adv_data = build_adv_data
    db = build_gatt_database
    @db = db
    @rx_handle = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @tx_handle = nus_handle(db, NUS_TX_CHAR_UUID, :value_handle)
    @tx_cccd_handle = nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION)
    @parser = StackchanProtocol::FrameParser.new
    @audio = StackchanApp::AudioReceiver.new(speaker: speaker, parser: @parser)
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, head: @head, stdout: self
    )
    ticker = StackchanApp::Ticker.new(
      display: @display, led: @led, touch: @touch, dispatcher: @dispatcher,
      notify: ->(frame) { write(frame) }
    )
    @link = StackchanApp::LinkLoop.new(
      port: self,
      rx_handle: @rx_handle, tx_handle: @tx_handle, cccd_handle: @tx_cccd_handle,
      ticker: ticker,
      on_packet: ->(pkt) { packet_callback(pkt) },
      on_rx: ->(data) { consume_rx(data) },
      clock: -> { Machine.uptime_us },
      log: ->(line) { puts line }
    )
    puts "[application] initialize: super(:peripheral) entering"
    super(:peripheral, db.profile_data)
    puts "[application] initialize: super returned"
  end

  # AckSink contract: Dispatcher calls write(frame_string) with one complete
  # newline-terminated frame. LinkLoop notifies it immediately, or drops it
  # while no central is subscribed.
  def write(frame)
    @link.write(frame)
  end

  # --- LinkLoop port: thin bridge to BLE's event queue / value store ---
  # (BLE#notify takes one argument and must not be shadowed, hence the names.)

  def pop_event(timeout_ms:)
    @event_queue.pop(timeout_ms: timeout_ms)
  end

  def event_popped
    _event_popped
  end

  def take_write(handle)
    pop_write_value(handle)
  end

  def send_notification(handle, frame)
    push_read_value(handle, frame)
    notify(handle)
  end

  # Own run loop instead of BLE#start (see LinkLoop for why). Never returns;
  # the controller stays up and connections persist. Mirrors start's setup and
  # its ensure (mrblib/ble.rb).
  def run
    @event_queue.clear
    _event_queue_cleared
    hci_power_control(HCI_POWER_ON)
    while true
      @link.tick
    end
  ensure
    hci_power_control(HCI_POWER_OFF)
  end

  def build_adv_data
    BLE::AdvertisingData.build do |a|
      a.add(AD_TYPE_FLAGS, AD_FLAGS)
      a.add(AD_TYPE_COMPLETE_LOCAL_NAME, "StackChan-PicoRuby")
    end
  end

  def build_gatt_database
    BLE::GattDatabase.new do |db|
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, BLE::GAP_SERVICE_UUID) do |s|
        s.add_characteristic(BLE::READ, BLE::GAP_DEVICE_NAME_UUID, BLE::READ, "StackChan-PicoRuby")
      end
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, NUS_SERVICE_UUID) do |s|
        s.add_characteristic(NUS_RX_PROPS, NUS_RX_CHAR_UUID, NUS_RX_PROPS, "")
        s.add_characteristic(NUS_TX_PROPS, NUS_TX_CHAR_UUID, NUS_TX_VAL_PROPS, "") do |c|
          c.add_descriptor(NUS_CCCD_PROPS, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
        end
      end
    end
  end

  def nus_handle(db, char_uuid, key)
    db.handle_table[NUS_SERVICE_UUID][char_uuid][key]
  end

  def packet_callback(event_packet)
    puts "[application] pkt evt=#{event_packet.getbyte(0) || 'nil'}"
    case event_packet.getbyte(0)
    when BTSTACK_EVENT_STATE
      return unless event_packet.getbyte(2) == BLE::HCI_STATE_WORKING
      puts "[application] HCI WORKING — advertising"
      advertise(@adv_data)
    when HCI_EVENT_DISCONNECTION_COMPLETE
      puts "[application] disconnected"
      @link.disconnected
      # Re-enable advertising so a central can reconnect; nothing else
      # re-advertises after a disconnect with the infinite run loop.
      advertise(@adv_data)
    end
  end

  # Route one RX chunk through the audio receiver: it accumulates raw mu-law
  # after a <A:N> control frame and plays (blocking) on completion, and yields
  # every non-audio frame back here for the dispatcher. Blocking playback during
  # the poll is fine — the Mac is idle by then and a sentence plays in ~1-3s
  # (< the ~15-20s idle-disconnect window). One <A:done> ACK per clip.
  def consume_rx(rx_data)
    done = @audio.consume(
      rx_data,
      notify_fn: ->(msg) { write(msg) },
      drain_fn:  -> { pop_write_value(@rx_handle) },
      # Keeps the ESP32 port's inbound queue draining every DRAIN_STEP_MS while
      # the audio wait blocks the run loop; a disconnect arriving during
      # playback is still dispatched through on_packet.
      pump_fn:   -> { @link.pump }
    ) { |frame| @dispatcher.handle(frame) }
    done.times { write("<A:done>\n") }
  end
end

# [4] Run the peripheral forever. StackChanApp#run is our own loop (a 20 ms
# tick that drains NimBLE's queues every time), not BLE#start — see
# StackchanApp::LinkLoop. An active central connection is never force-dropped.
puts "[application] BLE peripheral starting (infinite advertise)"
peri = StackChanApp.new(display: display, led: led, head: @head, touch: @touch, speaker: @speaker)
peri.debug = true
peri.run
