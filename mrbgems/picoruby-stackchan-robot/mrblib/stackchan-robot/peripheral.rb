module StackChan
  class Robot
    class Peripheral < BLE
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

      attr_reader :robot_handle

      def initialize(robot, display:, led:, head: nil, touch: nil, speaker: nil)
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
        wiring = robot.wire(
          display: display, led: led, head: head, touch: touch, speaker: speaker,
          stdout: self, notify: ->(frame) { write(frame) }
        )
        @dispatcher = wiring.dispatcher
        @robot_handle = wiring.handle
        ticker = wiring.ticker
        remote = wiring.remote
        drb = StackChan::Robot::DrbChannel.new(
          rx_handle:   nus_handle(db, DRB_RX_CHAR_UUID, :value_handle),
          tx_handle:   nus_handle(db, DRB_TX_CHAR_UUID, :value_handle),
          cccd_handle: nus_handle(db, DRB_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION),
          responder:   DRbBle::Responder.new(remote, allow: remote.exposed)
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
  end
end
