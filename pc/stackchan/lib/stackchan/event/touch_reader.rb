require_relative "../ble"

module Stackchan
  module Event
    # Bridges the BLE client's unsolicited touch frames into a Channel.
    # The BLE::Client's own reader thread invokes the on_unsolicited lambda
    # on every <touch:N> frame; we parse the zone and push a structured event.
    class TouchReader
      def initialize(ble_client, channel)
        @ble = ble_client
        @channel = channel
      end

      def start
        @ble.on_unsolicited = lambda do |frame|
          zone = Stackchan::BLE::FrameCodec.parse_touch(frame)
          @channel.push({ type: :touch, zone: zone }) if zone
        end
        self
      end
    end
  end
end
