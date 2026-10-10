module StackChan
  class Robot
    class LinkLoop
      TICK_MS = 20
      CCCD_NOTIFY = "\x01\x00"

      def initialize(port:, ticker:, on_packet:, clock:, drb:, remote:, release_after: nil)
        @port        = port
        @ticker      = ticker
        @on_packet   = on_packet
        @clock       = clock
        @drb         = drb
        @remote      = remote
        @release_after_us = release_after && release_after * 1000
        @active_at = nil
      end

      def tick
        event = @port.pop_event(timeout_ms: TICK_MS)
        @port.event_popped
        @on_packet.call(event) if event.is_a?(String)
        @active_at = @clock.call if @drb.service(@port)
        release_if_idle
        @ticker.tick(@clock.call / 1000)
        @active_at = @clock.call if @remote.perform_audio_play && @active_at
      end

      def disconnected
        @active_at = nil
        @drb.disconnected
      end

      private

      def release_if_idle
        return unless @release_after_us && @active_at
        return if @clock.call - @active_at < @release_after_us
        @active_at = nil
        @port.disconnect_central
      end
    end
  end
end
