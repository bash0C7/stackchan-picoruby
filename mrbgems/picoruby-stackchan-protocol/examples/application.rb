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
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-led'
require 'stackchan-protocol'
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
    EYE_LEFT_CX  = 110
    EYE_RIGHT_CX = 210
    EYE_LEFT_CY  = 100
    EYE_RIGHT_CY = 100
    EYE_RADIUS   = 18
    EYE_COLOR    = ILI9342::Color::WHITE

    MOUTH_CX     = 160
    MOUTH_CY     = 140
    MOUTH_HALF_WIDTH = 25

    SURPRISED_MOUTH_HALF_W = 6
    SURPRISED_MOUTH_HALF_H = 12

    BROW_OFFSET_Y    = 18
    BROW_HALF_LENGTH = 16
    BROW_INNER_DROP  = 8

    class Base
      DELTA_Y = 0

      def draw(display)
        display.fill(0x0000)
        draw_eyes(display)
        draw_mouth(display)
      end

      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RADIUS, EYE_RADIUS, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RADIUS, EYE_RADIUS, EYE_COLOR, fill: true)
      end

      def draw_mouth(display)
        corner_y = MOUTH_CY - self.class::DELTA_Y
        display.draw_line(MOUTH_CX - MOUTH_HALF_WIDTH, corner_y,
                          MOUTH_CX,                    MOUTH_CY, EYE_COLOR)
        display.draw_line(MOUTH_CX,                    MOUTH_CY,
                          MOUTH_CX + MOUTH_HALF_WIDTH, corner_y, EYE_COLOR)
      end

      def redraw_eyes_open(display)
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
      DELTA_Y = 0

      def draw(display)
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
        display.draw_rect(MOUTH_CX - SURPRISED_MOUTH_HALF_W, MOUTH_CY - SURPRISED_MOUTH_HALF_H,
                          SURPRISED_MOUTH_HALF_W * 2, SURPRISED_MOUTH_HALF_H * 2, EYE_COLOR, fill: true)
      end
    end

    class Closed < Base
      def draw_eyes(display)
        display.draw_line(EYE_LEFT_CX  - EYE_RADIUS, EYE_LEFT_CY,
                          EYE_LEFT_CX  + EYE_RADIUS, EYE_LEFT_CY,  EYE_COLOR)
        display.draw_line(EYE_RIGHT_CX - EYE_RADIUS, EYE_RIGHT_CY,
                          EYE_RIGHT_CX + EYE_RADIUS, EYE_RIGHT_CY, EYE_COLOR)
      end
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

py32 = PY32IOExpander.new(i2c)
py32.set_direction(0, true)
py32.set_pull_mode(0, true)
py32.digital_write(0, true)
Machine.delay_ms(200)

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

Machine.delay_ms(50)
led.show
led.brightness = 100
StackchanApp::Face::Neutral.new.draw(display)
puts "[application] LCD + LED cold-boot done"

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

  def initialize(display:, led:)
    @display = display
    @led     = led
    @adv_data = build_adv_data
    db = build_gatt_database
    @db = db
    @rx_handle = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @tx_handle = nus_handle(db, NUS_TX_CHAR_UUID, :value_handle)
    @tx_cccd_handle = nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION)
    @notify_enabled = false
    @parser = StackchanProtocol::FrameParser.new
    @ack_queue = ""
    @dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: self
    )
    puts "[application] initialize: super(:peripheral) entering"
    super(:peripheral, db.profile_data)
    puts "[application] initialize: super returned"
  end

  # AckSink contract: Dispatcher calls `write(byte)` to deliver an ACK byte.
  def write(byte)
    @ack_queue += byte
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
    when ATT_EVENT_CAN_SEND_NOW
      flush_one_ack
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
    # Request can_send_now if we have ACK bytes queued and the central is subscribed
    if @notify_enabled && @ack_queue.bytesize > 0
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

  def flush_one_ack
    return if @ack_queue.bytesize == 0
    byte = @ack_queue[0, 1]
    @ack_queue = @ack_queue[1, @ack_queue.bytesize - 1] || ""
    push_read_value(@tx_handle, byte)
    notify(@tx_handle)
  end
end

# [4] Run BTstack run_loop for 60_000ms. Phase 2 ble_smoke.rb で実証済みの引数で、
# 60s 経過後に start() は return する仕様 (引数は ms)。Phase 3 production として
# 常時 advertise したい場合の loop 化や別 N 値は未検証なので別件。60s 経過後は
# このスクリプトが終了し、R2P2 shell に制御が戻る (Phase 2 と同じ挙動)。
puts "[application] BLE peripheral starting (loop, 60s windows)"
peri = StackChanApp.new(display: display, led: led)
peri.debug = true
# Loop indefinitely. peri.start(60_000) blocks for 60s then returns; we restart
# immediately so the device stays advertise-able for HITL / smoke timing windows.
# 恒久対応 (peri.start の API 改善 / 無限 advertise) は別 task。
loop do
  peri.start(60_000)
  puts "[application] start returned (60s window expired, restarting)"
end
