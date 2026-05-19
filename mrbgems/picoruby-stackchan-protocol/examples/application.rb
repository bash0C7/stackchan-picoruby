# examples/application.rb — Phase 3 production dispatcher.
#
# Flow:
#   [1] 5s escape hatch (sleep_ms 5000) — crash-loop recovery window
#   [2] cold-boot init (AXP2101 → AW9523 → ILI9342 → PY32 → LED → Face::Neutral)
#   [3] BLE NUS service + Dispatcher + FrameParser + AckSink
#   [4] peri.start(60_000) — 60s advertise window (Phase 2 で実証された引数; 経過後 return)
#
# Upload: rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb
# Smoke:  rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'uart'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-led'
require 'stackchan-protocol'
require 'scservo'
require 'ble'

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
        display.fill(BACKGROUND_COLOR)
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

      # Override Base#draw to do eye-only update: no full-screen fill, no mouth
      # redraw. This is used as the "blink close" frame so screen does not
      # flicker visibly.
      def draw(display)
        clear_eye_region(display)
        draw_eyes(display)
      end
    end
  end

  class Head
    YAW_RANGE   = (-1280..1280)
    PITCH_RANGE = (30..870)

    def initialize(yaw_servo, pitch_servo)
      @yaw   = yaw_servo
      @pitch = pitch_servo
    end

    def apply(frame)
      time_ms, speed = resolve_time_speed(frame)
      if frame.key?("Y")
        y = clamp(frame["Y"].to_i, YAW_RANGE)
        @yaw.write_pos(y, time_ms: time_ms, speed: speed)
      end
      if frame.key?("P")
        p = clamp(frame["P"].to_i, PITCH_RANGE)
        @pitch.write_pos(p, time_ms: time_ms, speed: speed)
      end
    end

    def read_actual
      { "Y_actual" => @yaw.read_pos, "P_actual" => @pitch.read_pos }
    end

    private

    def resolve_time_speed(frame)
      # T-priority: T present -> use T, else V if present, else both zero (max speed)
      if frame.key?("T")
        [frame["T"].to_i, 0]
      elsif frame.key?("V")
        [0, frame["V"].to_i]
      else
        [0, 0]
      end
    end

    def clamp(v, range)
      return range.first if v < range.first
      return range.last  if v > range.last
      v
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

    attr_reader :current_face_class

    def initialize(display:, led:, stdout: $stdout, head: nil)
      @display = display
      @led     = led
      @stdout  = stdout
      @head    = head
      @current_face_class = Face::Neutral
    end

    def handle(frame)
      attempts = []
      attempts << handle_face(frame) if frame.key?("F")
      attempts << handle_led(frame)  if frame.key?("L")
      servo_present = frame.key?("Y") || frame.key?("P") || frame.key?("V") || frame.key?("T")
      handle_head(frame) if servo_present
      # Servo success/failure is reported in detail frame, not in ACK/ERROR byte
      # If attempts is empty (no F/L), success defaults to true
      success = attempts.empty? || attempts.all? { |ok| ok }
      @stdout.write(success ? ACK_FRAME : ERROR_FRAME)
      emit_servo_detail(frame) if servo_present
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
      return if @head.nil?
      @head.apply(frame)
    end

    def emit_servo_detail(frame)
      if @head.nil?
        @stdout.write("<ERROR:servo_unavailable>\n")
        return
      end
      actual = @head.read_actual
      failed = []
      failed << "yaw"   if actual["Y_actual"].nil? && frame.key?("Y")
      failed << "pitch" if actual["P_actual"].nil? && frame.key?("P")
      if failed.any?
        axis = failed.size == 2 ? "both" : failed.first
        @stdout.write("<ERROR:servo_timeout,axis:#{axis}>\n")
      else
        y = frame.key?("Y") ? actual["Y_actual"] : nil
        p = frame.key?("P") ? actual["P_actual"] : nil
        parts = []
        parts << "Y_actual:#{y}" if y
        parts << "P_actual:#{p}" if p
        # If only T or V given (no Y/P), still report both axes for visibility
        if parts.empty?
          parts << "Y_actual:#{actual['Y_actual']}"
          parts << "P_actual:#{actual['P_actual']}"
        end
        @stdout.write("<#{parts.join(',')}>\n")
      end
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
StackchanApp::Face::Neutral.new.draw(display)
puts "[application] LCD + LED cold-boot done"

# Phase B: servo bring-up. Failure must NOT block face/LED — keep @head=nil so
# Dispatcher can return <ERROR:servo_unavailable> while Phase A features stay live.
@head = nil
begin
  servo_uart = UART.new(unit: :ESP32_UART1, txd_pin: 7, rxd_pin: 6, baudrate: 1_000_000)
  yaw_servo   = SCServo.new(servo_uart, id: 1)
  pitch_servo = SCServo.new(servo_uart, id: 2)
  yaw_servo.enable_torque
  pitch_servo.enable_torque
  @head = StackchanApp::Head.new(yaw_servo, pitch_servo)
  puts "[boot] servo init OK"
rescue => e
  puts "[boot] servo init failed: #{e.class}: #{e.message}"
end

# Cold-boot self-test: human-visible LED + servo motion so anyone watching
# the device can tell at a glance whether each subsystem (LED bus / servo
# UART TX / servo UART RX) is alive. Each step puts a log line so a Mac-side
# `bin/capture-with-pty` operator can correlate visual with serial trace.
# Failure of any leg is non-fatal — BLE startup proceeds either way.
puts "[boot] self-test begin"

begin
  puts "[boot] self-test led: left red solid"
  led.animate_side(:left, 255, 0, 0, :solid)
  led.tick(Machine.uptime_us / 1000)
  Machine.delay_ms(1500)
  puts "[boot] self-test led: right blue solid"
  led.animate_side(:right, 0, 0, 255, :solid)
  led.tick(Machine.uptime_us / 1000)
  Machine.delay_ms(1500)
  puts "[boot] self-test led: both off"
  led.animate_side(:both, 0, 0, 0, :off)
  led.tick(Machine.uptime_us / 1000)
rescue => e
  puts "[boot] self-test led raised: #{e.class}: #{e.message}"
end

if @head
  begin
    [
      ["up",     "0",     "800"],
      ["down",   "0",     "200"],
      ["right",  "1000",  "450"],
      ["left",   "-1000", "450"],
      ["center", "0",     "450"],
    ].each do |label, y, p|
      puts "[boot] self-test servo: #{label} Y=#{y} P=#{p}"
      @head.apply({"Y" => y, "P" => p, "T" => "600"})
      Machine.delay_ms(800)
    end
    actual = @head.read_actual
    puts "[boot] self-test servo read=#{actual.inspect}"
  rescue => e
    puts "[boot] self-test servo raised: #{e.class}: #{e.message}"
  end
else
  puts "[boot] self-test servo: SKIP (@head nil)"
end

puts "[boot] self-test end"

# cold-boot block (AXP2101/AW9523/SPI/ILI9342/PY32/LED/Face::Neutral.draw) は
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
      StackchanApp::Face::Closed.new.draw(@display)
      Machine.delay_ms 150
      @dispatcher.current_face_class.new.redraw_eyes_open(@display)
    end
  end

  def flush_one_frame
    return if @notify_queue.empty?
    frame = @notify_queue.shift
    push_read_value(@tx_handle, frame)
    notify(@tx_handle)
  end
end

# [4] Run BTstack run_loop for 60_000ms. Phase 2 ble_smoke.rb で実証済みの引数で、
# 60s 経過後に start() は return する仕様 (引数は ms)。Phase 3 production として
# 常時 advertise したい場合の loop 化や別 N 値は未検証なので別件。60s 経過後は
# このスクリプトが終了し、R2P2 shell に制御が戻る (Phase 2 と同じ挙動)。
puts "[application] BLE peripheral starting (loop, 60s windows)"
peri = StackChanApp.new(display: display, led: led, head: @head)
peri.debug = true
# Loop indefinitely. peri.start(60_000) blocks for 60s then returns; we restart
# immediately so the device stays advertise-able for HITL / smoke timing windows.
# 恒久対応 (peri.start の API 改善 / 無限 advertise) は別 task。
loop do
  peri.start(60_000)
  puts "[application] start returned (60s window expired, restarting)"
end
