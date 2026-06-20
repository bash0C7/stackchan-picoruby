require_relative "../ble"

module Stackchan
  module Event
    # Bridges the BLE client's unsolicited touch frames into a Channel.
    # The BLE::Client's own reader thread invokes the on_unsolicited lambda
    # on every <touch:N> frame; we parse the zone and push a structured event.
    class TouchReader
      # on_touch: optional callable invoked with the event hash BEFORE the
      # event is pushed onto the channel. Used by the daemon to give the
      # human immediate face feedback regardless of whether anyone is
      # currently subscribed via `touch listen`.
      def initialize(ble_client, channel, on_touch: nil)
        @ble = ble_client
        @channel = channel
        @on_touch = on_touch
      end

      def start
        @ble.on_unsolicited = lambda do |frame|
          zone = Stackchan::BLE::FrameCodec.parse_touch(frame)
          next unless zone
          event = { type: :touch, zone: zone }
          begin
            @on_touch&.call(event)
          rescue StandardError => e
            $stderr.puts "[touch_reader] on_touch failed: #{e.class}: #{e.message}"
          end
          @channel.push(event)
        end
        self
      end
    end
  end
end
