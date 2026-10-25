module StackChan
  class Robot
    # The BLE peripheral. Builds the advertising data and GATT table, wires the robot and runs the link loop.
    class Peripheral < BLE
      AD_TYPE_FLAGS = 0x01
      AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
      AD_FLAGS = 0x06
      BTSTACK_EVENT_STATE = 0x60
      HCI_EVENT_DISCONNECTION_COMPLETE = 0x05
      ATT_EVENT_MTU_EXCHANGE_COMPLETE = 0xB5

      DRB_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
      DRB_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x04\x00\x40\x6e"
      DRB_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x05\x00\x40\x6e"

      DRB_RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
      DRB_TX_PROPS = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
      DRB_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
      CCCD_PROPS = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

      SERVICE_CHANGED_CHAR_UUID = 0x2A05

      # @rbs @adv_data: untyped
      # @rbs @dispatcher: Dispatcher
      # @rbs @link: LinkLoop

      attr_reader :robot_handle #: Handle

      # Wires the robot to the devices, builds the GATT database and the link loop, and starts the BLE peripheral.
      #: (Robot robot, display: untyped, led: untyped, ?head: untyped, ?touch: untyped, ?speaker: untyped) -> void
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

      # Pops the next BLE event, waiting up to timeout_ms. Returns nil on timeout.
      #: (timeout_ms: Integer) -> untyped
      def pop_event(timeout_ms:)
        @event_queue.pop(timeout_ms: timeout_ms)
      end

      # Tells the BLE layer an event pop has finished.
      #: () -> untyped
      def event_popped
        _event_popped
      end

      # Returns the value last written by the central to the characteristic handle.
      #: (Integer handle) -> untyped
      def take_write(handle)
        pop_write_value(handle)
      end

      # Disconnects the connected central.
      #: () -> untyped
      def disconnect_central
        disconnect
      end

      # Stores frame as the characteristic value and notifies the central.
      #: (Integer handle, String frame) -> untyped
      def send_notification(handle, frame)
        push_read_value(handle, frame)
        notify(handle)
      end

      # Powers the HCI on and loops over LinkLoop#tick forever; powers it off on exit.
      #: () -> void
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

      # Builds the advertising data: flags and the local name StackChan-PicoRuby.
      #: () -> untyped
      def build_adv_data
        BLE::AdvertisingData.build do |a|
          a.add(AD_TYPE_FLAGS, AD_FLAGS)
          a.add(AD_TYPE_COMPLETE_LOCAL_NAME, "StackChan-PicoRuby")
        end
      end

      # Builds the GATT table: GAP device name, the dRuby RX/TX pair with its CCCD, and Service Changed.
      #: () -> untyped
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

      # Looks up an attribute handle of the dRuby service in the GATT database.
      #: (untyped db, String char_uuid, untyped key) -> Integer
      def drb_handle(db, char_uuid, key)
        db.handle_table[DRB_SERVICE_UUID][char_uuid][key]
      end

      # Handles a BLE event packet: advertises when the HCI is working or after a disconnect, starts the idle timer on MTU exchange.
      #: (String event_packet) -> void
      def packet_callback(event_packet)
        case event_packet.getbyte(0)
        when BTSTACK_EVENT_STATE
          return unless event_packet.getbyte(2) == BLE::HCI_STATE_WORKING
          puts "[application] HCI WORKING — advertising"
          advertise(@adv_data)
        when ATT_EVENT_MTU_EXCHANGE_COMPLETE
          @link.central_arrived
        when HCI_EVENT_DISCONNECTION_COMPLETE
          puts "[application] disconnected"
          @link.disconnected
          advertise(@adv_data)
        end
      end
    end
  end
end
