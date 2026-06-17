# app/application.rb — Phase 3 production dispatcher.
#
# Flow:
#   [1] 5s escape hatch (sleep_ms 5000) — crash-loop recovery window
#   [2] cold-boot init (AXP2101 → AW9523 → ILI9342 → PY32 → LED → Face::Neutral)
#   [3] BLE NUS service + Dispatcher + FrameParser + AckSink
#   [4] peri.start(60_000) — 60s advertise window (Phase 2 で実証された引数; 経過後 return)
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
      apply_immediately
    end

    def tick(now_ms)
      return unless dynamic?
      @phase_start_ms ||= now_ms
      elapsed = now_ms - @phase_start_ms
      case @mode
      when :blink
        on = (elapsed / BLINK_HALF_PERIOD_MS) % 2 == 0
        apply_color(on ? @r : 0, on ? @g : 0, on ? @b : 0)
      when :breathing
        ratio = BREATHING_LUT[(elapsed / BREATHING_STEP_MS) % BREATHING_LUT.size]
        apply_color(@r * ratio / 100, @g * ratio / 100, @b * ratio / 100)
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

  def tick(now_ms)
    left_animator.tick(now_ms)
    right_animator.tick(now_ms)
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

      def draw(display)
        display.draw_rect(0, 0, 320, FACE_REGION_HEIGHT, BACKGROUND_COLOR, fill: true)
        draw_eyes(display)
        draw_mouth(display)
      end

      # Clear the small bounding box around each eye to BACKGROUND_COLOR,
      # without touching the mouth or wider background. Used to wipe the
      # previous eye shape (open ellipse or closed line) before redrawing.
      def clear_eye_region(display)
        display.draw_rect(EYE_LEFT_CX  - EYE_REGION_HALF_W, EYE_LEFT_CY  - EYE_REGION_HALF_H,
                          EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                          BACKGROUND_COLOR, fill: true)
        display.draw_rect(EYE_RIGHT_CX - EYE_REGION_HALF_W, EYE_RIGHT_CY - EYE_REGION_HALF_H,
                          EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                          BACKGROUND_COLOR, fill: true)
      end

      # Update only the eye region (clear + redraw eyes), keeping the mouth
      # and overall background untouched. Used for blink restore.
      def redraw_eyes_open(display)
        clear_eye_region(display)
        draw_eyes(display)
      end

      # Eye-only update that closes the eyes (horizontal line), used for blink
      # animation. Mirrors redraw_eyes_open but draws closed-eye geometry. Does
      # NOT fill background — preserves whatever mouth / other face state is
      # already on screen.
      def redraw_eyes_closed(display)
        clear_eye_region(display)
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

      def draw(display)
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

      # Full-face draw: black background + closed eyes only (no mouth).
      # Used as the "torque off" idle indicator. For blink animation use
      # Base#redraw_eyes_closed instead (eye-only, no flicker).
      def draw(display)
        display.draw_rect(0, 0, 320, FACE_REGION_HEIGHT, BACKGROUND_COLOR, fill: true)
        draw_eyes(display)
        # No mouth — torque-off idle face is intentionally mouthless.
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

    private

    def handle_face(frame)
      face_class = FACE_TABLE[frame["F"]]
      return false unless face_class
      @current_face_class = face_class
      face_class.new.draw(@display)
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
        Face::Neutral.new.draw(@display)
        @stdout.write(ACK_FRAME)
      when "off"
        @head.enable_torque(false) if @head
        @current_face_class = Face::Closed
        Face::Closed.new.draw(@display)
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
class StackChanApp < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
  AD_FLAGS = 0x06
  BTSTACK_EVENT_STATE = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05
  ATT_EVENT_CAN_SEND_NOW = 0xB7

  NUS_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  NUS_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  NUS_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x03\x00\x40\x6e"

  NUS_RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
  NUS_TX_PROPS = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
  NUS_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
  NUS_CCCD_PROPS = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize(display:, led:, head: nil)
    @display = display
    @led     = led
    @head    = head
    @adv_data = build_adv_data
    db = build_gatt_database
    @db = db
    @rx_handle = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @tx_handle = nus_handle(db, NUS_TX_CHAR_UUID, :value_handle)
    @tx_cccd_handle = nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION)
    @notify_enabled = false
    @parser = StackchanProtocol::FrameParser.new
    @notify_queue = []
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, head: @head, stdout: self
    )
    puts "[application] initialize: super(:peripheral) entering"
    super(:peripheral, db.profile_data)
    puts "[application] initialize: super returned"
  end

  # AckSink contract: Dispatcher calls write(frame_string) with one complete
  # newline-terminated frame. We queue each frame as a separate element so the
  # heartbeat-driven flush sends exactly one BLE notification per frame.
  def write(frame)
    @notify_queue << frame
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
    puts "[application] pkt evt=#{event_packet[0] ? event_packet[0].ord : 'nil'}"
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      return unless event_packet[2]&.ord == BLE::HCI_STATE_WORKING
      puts "[application] HCI WORKING — advertising"
      advertise(@adv_data)
    when HCI_EVENT_DISCONNECTION_COMPLETE
      puts "[application] disconnected"
      @notify_enabled = false
      @notify_queue = []
      # Re-enable advertising so a central can reconnect. With the infinite
      # run loop (no 60s HCI power-cycle), nothing else re-advertises after a
      # disconnect — the old loop+start(60_000) relied on the boundary
      # power-cycle's BTSTACK_EVENT_STATE → advertise side effect for this.
      advertise(@adv_data)
    when ATT_EVENT_CAN_SEND_NOW
      flush_one_frame
    end
  end

  def heartbeat_callback
    puts "[application] heartbeat"
    # NUS RX drain
    rx_data = pop_write_value(@rx_handle)
    while rx_data
      @parser.feed(rx_data).each do |frame|
        @dispatcher.handle(frame)
      end
      rx_data = pop_write_value(@rx_handle)
    end
    # CCCD subscribe state
    cccd = pop_write_value(@tx_cccd_handle)
    if cccd
      @notify_enabled = (cccd == "\x01\x00")
      puts "[application] notify #{@notify_enabled ? 'enabled' : 'disabled'}"
    end
    # Tick LED animator
    @led.tick(Machine.uptime_us / 1000)
    # Request can_send_now if we have frames queued and the central is subscribed
    if @notify_enabled && !@notify_queue.empty?
      request_can_send_now_event
    end
    # Blink for liveness indicator. Tick is ~1s on R2P2-ESP32 (memory:
    # project_picoruby_ble_heartbeat_tick_one_second). 5 tick = ~5s 周期で
    # 1 tick だけ Closed (目つむり) → 同 tick 内で current face を再描画して
    # 「瞬き」演出。これがあれば人間がフリーズ vs 稼働中を視認できる。
    @blink_tick = (@blink_tick || 0) + 1
    if @blink_tick % 5 == 0
      @dispatcher.current_face_class.new.redraw_eyes_closed(@display)
      Machine.delay_ms 150
      @dispatcher.current_face_class.new.redraw_eyes_open(@display)
    end
  end

  def flush_one_frame
    return if @notify_queue.empty?
    frame = @notify_queue.shift
    push_read_value(@tx_handle, frame)
    notify(@tx_handle)
    # Chain: if more frames are queued, request another CAN_SEND_NOW immediately
    # so the rest of the queue drains at BLE conn-interval pace (~110ms measured)
    # instead of waiting for the next heartbeat tick (~1s). Without this, a
    # 2-frame response (ACK + detail) takes ~1s/frame and a 3-command burst
    # overruns the host's ack_timeout (3s).
    request_can_send_now_event unless @notify_queue.empty?
  end
end

# [4] Run BTstack run_loop for 60_000ms. Phase 2 ble_smoke.rb で実証済みの引数で、
# 60s 経過後に start() は return する仕様 (引数は ms)。Phase 3 production として
# 常時 advertise したい場合の loop 化や別 N 値は未検証なので別件。60s 経過後は
# このスクリプトが終了し、R2P2 shell に制御が戻る (Phase 2 と同じ挙動)。
puts "[application] BLE peripheral starting (infinite advertise)"
peri = StackChanApp.new(display: display, led: led, head: @head)
peri.debug = true
# Run the BTstack run loop indefinitely (start with no timeout). An active
# central connection is therefore never force-dropped.
#
# Previously this was `loop { peri.start(60_000) }`. ble.rb#start runs a
# polling loop until timeout_ms elapses, then its `ensure` block calls
# hci_power_control(HCI_POWER_OFF) — powering off the BT controller every
# 60s and tearing down any live connection at the window boundary. An
# operator connecting at a random point in the 60s window got 0–60s of link
# time, which made operator-paced HITL calibration impossible ("timing too
# tight"). start(nil) never hits the timeout break and only powers off on
# exception, so the controller stays up and connections persist.
peri.start
