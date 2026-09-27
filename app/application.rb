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

sleep_ms 5000

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
i2c.write(AXP2101_ADDR, 0x92, 13)
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

# REQUIRED FOR PY32 COLD-BOOT
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
rescue IOError => e
  led_init_attempt += 1
  if led_init_attempt < 6
    Machine.delay_ms(200)
    retry
  end
  raise e
end
puts "[boot] step:led-init-ok"

Machine.delay_ms(50)
led.show
puts "[boot] step:led-show-ok"
StackChan::Robot::Face.new(eyes: :closed, mouth: :none).draw(display)
puts "[application] LCD cold-boot done (torque-OFF idle)"
@touch = nil
begin
  @touch = Si12T.new(i2c)
  puts "[boot] step:si12t-init-ok"
rescue => e
  puts "[boot] si12t init failed: #{e.class}: #{e.message}"
end

@head = nil
begin
  servo_uart = UART.new(unit: :ESP32_UART1, txd_pin: 6, rxd_pin: 7, baudrate: 1_000_000)
  yaw_servo   = SCServo.new(servo_uart, id: 1)
  pitch_servo = SCServo.new(servo_uart, id: 2)
  yaw_servo.enable_torque(false)
  pitch_servo.enable_torque(false)
  @head = StackChan::Robot::Head.new(yaw_servo, pitch_servo)
  puts "[boot] servo init OK (torque OFF, awaiting <torque:on>)"
rescue => e
  puts "[boot] servo init failed: #{e.class}: #{e.message}"
end

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

sleep_ms 3000

class StackChanApp < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
  AD_FLAGS = 0x06
  BTSTACK_EVENT_STATE = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05

  NUS_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  NUS_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  NUS_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x03\x00\x40\x6e"
  DRB_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x04\x00\x40\x6e"
  DRB_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x05\x00\x40\x6e"

  NUS_RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
  NUS_TX_PROPS = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
  NUS_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
  NUS_CCCD_PROPS = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize(display:, led:, head: nil, touch: nil, speaker: nil)
    @adv_data = build_adv_data
    db = build_gatt_database
    @rx_handle = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @audio = StackChan::Robot::AudioReceiver.new(
      speaker: speaker,
      parser:  StackchanProtocol::FrameParser.new,
      notify:  ->(msg) { write(msg) },
      drain:   -> { pop_write_value(@rx_handle) },
      pump:    -> { @link.pump }
    )
    @dispatcher = StackChan::Robot::Dispatcher.new(
      display: display, led: led, head: head, stdout: self
    )
    ticker = StackChan::Robot::Ticker.new(
      display: display, led: led, touch: touch, dispatcher: @dispatcher,
      notify: ->(frame) { write(frame) }
    )
    drb = StackChan::Robot::DrbChannel.new(
      rx_handle:   nus_handle(db, DRB_RX_CHAR_UUID, :value_handle),
      tx_handle:   nus_handle(db, DRB_TX_CHAR_UUID, :value_handle),
      cccd_handle: nus_handle(db, DRB_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION),
      responder:   DRbBle::Responder.new(StackChan::Robot::Remote.new(@dispatcher),
                                         allow: StackChan::Robot::Remote::EXPOSED)
    )
    @link = StackChan::Robot::LinkLoop.new(
      port: self,
      rx_handle: @rx_handle,
      tx_handle: nus_handle(db, NUS_TX_CHAR_UUID, :value_handle),
      cccd_handle: nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION),
      ticker: ticker,
      on_packet: ->(pkt) { packet_callback(pkt) },
      on_rx: ->(data) { consume_rx(data) },
      clock: -> { Machine.uptime_us },
      log: ->(line) { puts line },
      drb: drb
    )
    super(:peripheral, db.profile_data)
  end

  def write(frame)
    @link.write(frame)
  end

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
        s.add_characteristic(NUS_RX_PROPS, DRB_RX_CHAR_UUID, NUS_RX_PROPS, "")
        s.add_characteristic(NUS_TX_PROPS, DRB_TX_CHAR_UUID, NUS_TX_VAL_PROPS, "") do |c|
          c.add_descriptor(NUS_CCCD_PROPS, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
        end
      end
    end
  end

  def nus_handle(db, char_uuid, key)
    db.handle_table[NUS_SERVICE_UUID][char_uuid][key]
  end

  def packet_callback(event_packet)
    case event_packet.getbyte(0)
    when BTSTACK_EVENT_STATE
      return unless event_packet.getbyte(2) == BLE::HCI_STATE_WORKING
      puts "[application] HCI WORKING — advertising"
      advertise(@adv_data)
    when HCI_EVENT_DISCONNECTION_COMPLETE
      puts "[application] disconnected"
      @link.disconnected
      advertise(@adv_data)
    end
  end

  def consume_rx(rx_data)
    write("<A:done>\n") if @audio.consume(rx_data) { |frame| @dispatcher.handle(frame) }
  end
end

puts "[application] BLE peripheral starting (infinite advertise)"
peri = StackChanApp.new(display: display, led: led, head: @head, touch: @touch, speaker: @speaker)
peri.run
