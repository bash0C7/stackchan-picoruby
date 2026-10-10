module StackChan
  class Robot
    class Peripheral < BLE
      AD_TYPE_FLAGS = 0x01
      AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
      AD_FLAGS = 0x06
      BTSTACK_EVENT_STATE = 0x60
      HCI_EVENT_DISCONNECTION_COMPLETE = 0x05

      DRB_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
      DRB_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x04\x00\x40\x6e"
      DRB_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x05\x00\x40\x6e"

      DRB_RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
      DRB_TX_PROPS = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
      DRB_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
      CCCD_PROPS = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

      SERVICE_CHANGED_CHAR_UUID = 0x2A05

      attr_reader :robot_handle

      def initialize(robot, display:, led:, head: nil, touch: nil, speaker: nil)
        @adv_data = build_adv_data
        db = build_gatt_database
        wiring = robot.wire(
          display: display, led: led, head: head, touch: touch, speaker: speaker
        )
        @dispatcher = wiring.dispatcher
        @robot_handle = wiring.handle
        ticker = wiring.ticker
        remote = wiring.remote
        drb = StackChan::Robot::DrbChannel.new(
          rx_handle:   drb_handle(db, DRB_RX_CHAR_UUID, :value_handle),
          tx_handle:   drb_handle(db, DRB_TX_CHAR_UUID, :value_handle),
          cccd_handle: drb_handle(db, DRB_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION),
          responder:   DRbBle::Responder.new(remote, allow: remote.exposed)
        )
        @link = StackChan::Robot::LinkLoop.new(
          port: self,
          ticker: ticker,
          on_packet: ->(pkt) { packet_callback(pkt) },
          clock: -> { Machine.uptime_us },
          drb: drb,
          remote: remote,
          release_after: robot.release_after
        )
        super(:peripheral, db.profile_data)
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

      def disconnect_central
        disconnect
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
          db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, DRB_SERVICE_UUID) do |s|
            s.add_characteristic(DRB_RX_PROPS, DRB_RX_CHAR_UUID, DRB_RX_PROPS, "")
            s.add_characteristic(DRB_TX_PROPS, DRB_TX_CHAR_UUID, DRB_TX_VAL_PROPS, "") do |c|
              c.add_descriptor(CCCD_PROPS, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
            end
          end
          db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, BLE::GATT_SERVICE_UUID) do |s|
            s.add_characteristic(BLE::INDICATE, SERVICE_CHANGED_CHAR_UUID, BLE::INDICATE, "\x00\x00\xFF\xFF") do |c|
              c.add_descriptor(CCCD_PROPS, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
            end
          end
        end
      end

      def drb_handle(db, char_uuid, key)
        db.handle_table[DRB_SERVICE_UUID][char_uuid][key]
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
    end
  end
end
