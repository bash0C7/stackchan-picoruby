# StackChan autostart payload (/home/app.mrb):
#   [1] escape hatch → [2] cold-boot init → [3] BLE NUS peripheral → [4] run loop

#   Driver gems under mrbgems/ (stackchan-led, si12t, aw88298) are bundled in by the Rakefile at compile time.
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

# [1] Escape hatch: time to reach the shell and rm /home/app.mrb if this build crash-loops.
sleep_ms 5000

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

    SURPRISED_MOUTH_HALF_W = 6
    SURPRISED_MOUTH_HALF_H = 12

    BROW_OFFSET_Y    = 18   # baseline 18px above eye centerline
    BROW_HALF_LENGTH = 16   # horizontal extent each side of eye cx
    BROW_INNER_DROP  = 8    # inner end of brow drops 8px relative to outer end

    # Every face paints inside these two bands, so an expression change
    # repaints ~5600 px instead of the whole field.
    FEATURE_MARGIN = 2
    MOUTH_MAX_RISE = 18
    EYE_BAND_X   = EYE_LEFT_CX - BROW_HALF_LENGTH - FEATURE_MARGIN
    EYE_BAND_W   = (EYE_RIGHT_CX + BROW_HALF_LENGTH + FEATURE_MARGIN) - EYE_BAND_X
    EYE_BAND_Y   = EYE_LEFT_CY - BROW_OFFSET_Y - FEATURE_MARGIN
    EYE_BAND_H   = (EYE_LEFT_CY + EYE_RY + FEATURE_MARGIN) - EYE_BAND_Y
    MOUTH_BAND_X = MOUTH_CX - MOUTH_HALF_WIDTH - FEATURE_MARGIN
    MOUTH_BAND_W = (MOUTH_CX + MOUTH_HALF_WIDTH + FEATURE_MARGIN) - MOUTH_BAND_X
    MOUTH_BAND_Y = MOUTH_CY - MOUTH_MAX_RISE - FEATURE_MARGIN
    MOUTH_BAND_H = (MOUTH_CY + SURPRISED_MOUTH_HALF_H + FEATURE_MARGIN) - MOUTH_BAND_Y


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

      # Full repaint (cold boot).
      def draw(display)
        display.draw_rect(0, 0, 320, FACE_REGION_HEIGHT, BACKGROUND_COLOR, fill: true)
        draw_features(display)
      end

      # What this face paints on the black field; subclasses extend this, not draw.
      def draw_features(display)
        draw_eyes(display)
        draw_mouth(display)
      end

      # Repaint over an existing face: clear only the bands, then paint.
      def redraw(display)
        display.draw_rect(EYE_BAND_X, EYE_BAND_Y, EYE_BAND_W, EYE_BAND_H,
                          BACKGROUND_COLOR, fill: true)
        display.draw_rect(MOUTH_BAND_X, MOUTH_BAND_Y, MOUTH_BAND_W, MOUTH_BAND_H,
                          BACKGROUND_COLOR, fill: true)
        draw_features(display)
      end

      def clear_eye_region(display)
        display.draw_rect(EYE_LEFT_CX  - EYE_REGION_HALF_W, EYE_LEFT_CY  - EYE_REGION_HALF_H,
                          EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                          BACKGROUND_COLOR, fill: true)
        display.draw_rect(EYE_RIGHT_CX - EYE_REGION_HALF_W, EYE_RIGHT_CY - EYE_REGION_HALF_H,
                          EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                          BACKGROUND_COLOR, fill: true)
      end

      def redraw_eyes_open(display)
        clear_eye_region(display)
        draw_eyes(display)
      end

      # Eye-only closed-eye update for blink; leaves the mouth alone.
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

      def draw_features(display)
        super
        display.draw_line(
          EYE_LEFT_CX - BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y,
          EYE_LEFT_CX + BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_COLOR
        )
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

    # Eye box for eye-only updates; covers both the open ellipse and the closed line.
    EYE_REGION_HALF_W = 6
    EYE_REGION_HALF_H = 6

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

      # Torque-off idle face: closed eyes, no mouth.
      def draw_features(display)
        draw_eyes(display)
      end
    end
  end

  class Head
    # Raw units per 90° from forward, from `stackchan calibrate`:
    #   yaw forward=482, left max=182, right max=783; pitch forward=633, up max=929.
    YAW_RANGE_RAW   = 300
    PITCH_RANGE_RAW = 296

    # Forward (zero) raw positions, read after the operator aligns the head by hand.
    SERVO_YAW_ZERO   = 482
    SERVO_PITCH_ZERO = 633

    def initialize(yaw_servo, pitch_servo)
      @yaw   = yaw_servo
      @pitch = pitch_servo
    end

    def apply(yaw_raw: nil, pitch_raw: nil, time_ms: 0, velocity: 0)
      @yaw.write_pos(yaw_raw, time_ms: time_ms, speed: velocity)     if yaw_raw
      @pitch.write_pos(pitch_raw, time_ms: time_ms, speed: velocity) if pitch_raw
    end

    def enable_torque(on)
      @yaw.enable_torque(on)   if @yaw
      @pitch.enable_torque(on) if @pitch
    end

    def read_actual
      { yaw: (@yaw && @yaw.read_pos), pitch: (@pitch && @pitch.read_pos) }
    end

    # <selftest:run>: nudge yaw ±10 raw and return to center (UART round-trip check).
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

    # Touch zone → face, drawn on-device the instant Si12T fires.
    TOUCH_FACE_TABLE = {
      0 => Face::Surprised,
      1 => Face::Angry,
      2 => Face::Sad,
    }.freeze

    # Touch zone → LED [side, r, g, b].
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
      # Raw Y/P keys are not part of the protocol.
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

    # Touch reaction: draw the zone's face locally (no PC round-trip).
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

      # Raw below the forward zero is StackChan's left, above is its right:
      # YL subtracts, YR adds.
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

    # Reports the pose at command receipt, not after the move: waiting out T
    # would stall LinkLoop. Its job is the `unknown` signal; a post-move pose
    # comes from <read:pos>.
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
    end
  end
end

module StackchanApp
  # Half-duplex audio receiver. On <A:N>: notify <A:ready>, block T ms,
  # drain the accumulated bytes, play. Non-audio frames are yielded to the block.
  class AudioReceiver
    # 200ms of silence overwrites all I2S DMA circular descriptors so the last
    # audio frame does not replay at EOF.
    SILENCE_TAIL = ("\x00" * 3200)

    # Wait in short steps: the ESP32 port's inbound queue (depth 32) overflows
    # if a whole clip is waited out in one call.
    DRAIN_STEP_MS = 50

    def initialize(speaker:, parser:)
      @speaker = speaker
      @parser  = parser
    end

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
      # PC READY_WAIT 1500 ms + blast (n/8000 s) + 1500 ms margin.
      (n * 1000 / 8000) + 3000
    end

    def wait_and_drain(t, drain_fn, pump_fn)
      buf = ""
      waited = 0
      while waited < t
        step = t - waited
        step = DRAIN_STEP_MS if step > DRAIN_STEP_MS
        Machine.delay_ms(step)
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
  # Periodic work (touch poll, LED animation, blink). Pure: caller passes now_ms.
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

    def poll_touch
      return unless @touch
      zone = @touch.poll
      return unless zone
      @dispatcher.react_to_touch(zone)
      @notify.call("<touch:#{zone}>\n")
    rescue => e
      puts "[application] touch poll error: #{e.class}: #{e.message}"
    end

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

  # One tick of the peripheral run loop. `event_popped` runs on EVERY tick: on
  # the ESP32 port inbound writes reach Ruby only inside BLE#_event_popped, and
  # BLE#start would call it only after the 1 s heartbeat.
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

# [2] cold-boot init. Order is critical; see CLAUDE.md "cold-boot 初期化"
# for the why behind each I2C write.
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

# REQUIRED FOR PY32 COLD-BOOT: the puts in this block prevent a
# LoadProhibited crash in the PY32 init region (bytecode-layout dependent;
# removing one shifts the crash a line later). Not debug logs.
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
# Head touch reuses the system I2C. Optional; failure keeps @touch=nil.
@touch = nil
begin
  @touch = Si12T.new(i2c)
  puts "[boot] step:si12t-init-ok"
rescue => e
  puts "[boot] si12t init failed: #{e.class}: #{e.message}"
end

# Servos: torque stays OFF until <torque:on>. Optional; failure keeps @head=nil.
@head = nil
begin
  # ESP32 TX on GPIO 6, RX on GPIO 7 (StackChan hal_servo.cpp); swapped pins give silent RX.
  servo_uart = UART.new(unit: :ESP32_UART1, txd_pin: 6, rxd_pin: 7, baudrate: 1_000_000)
  yaw_servo   = SCServo.new(servo_uart, id: 1)
  pitch_servo = SCServo.new(servo_uart, id: 2)
  # SCS EEPROM default is torque ON; cold boot wants it OFF.
  yaw_servo.enable_torque(false)
  pitch_servo.enable_torque(false)
  @head = StackchanApp::Head.new(yaw_servo, pitch_servo)
  puts "[boot] servo init OK (torque OFF, awaiting <torque:on>)"
rescue => e
  puts "[boot] servo init failed: #{e.class}: #{e.message}"
end

# Speaker: AW88298 over system I2C + I2S TX on GPIO13 at 8 kHz. Optional; failure keeps @speaker=nil.
SPEAKER_SAMPLE_RATE = 8000
@speaker = nil
begin
  speaker_i2s = I2S.new(sample_rate: SPEAKER_SAMPLE_RATE)
  @speaker = AW88298.new(i2c: i2c, i2s: speaker_i2s)
  @speaker.init_amp(SPEAKER_SAMPLE_RATE)
  puts "[boot] speaker init OK (AW88298 @ 0x36 + I2S @ #{SPEAKER_SAMPLE_RATE}Hz)"
rescue => e
  puts "[boot] speaker init failed: #{e.class}: #{e.message}"
end

# The cold-boot block above is synchronous I2C/SPI and starves the NimBLE
# host task. Without this yield BLE.new/start looks fine in the log but
# nothing is emitted over RF.
sleep_ms 3000

# [3] BLE NUS peripheral. Per-tick logic lives in LinkLoop, periodic work in Ticker.
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

  # AckSink: one newline-terminated frame; dropped while no central is subscribed.
  def write(frame)
    @link.write(frame)
  end

  # LinkLoop port. (BLE#notify takes one argument and must not be shadowed.)

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

  # Own run loop instead of BLE#start; mirrors start's setup and ensure (mrblib/ble.rb).
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
      # Re-advertise so a central can reconnect.
      advertise(@adv_data)
    end
  end

  # Audio frames go to the receiver (blocking playback); everything else to the dispatcher.
  def consume_rx(rx_data)
    done = @audio.consume(
      rx_data,
      notify_fn: ->(msg) { write(msg) },
      drain_fn:  -> { pop_write_value(@rx_handle) },
      pump_fn:   -> { @link.pump }
    ) { |frame| @dispatcher.handle(frame) }
    done.times { write("<A:done>\n") }
  end
end

# [4] Run forever. StackChanApp#run is our own 20 ms tick loop, not BLE#start.
puts "[application] BLE peripheral starting (infinite advertise)"
peri = StackChanApp.new(display: display, led: led, head: @head, touch: @touch, speaker: @speaker)
peri.debug = true
peri.run
