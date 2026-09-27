module StackChan
  class Robot
    class LinkLoop
      TICK_MS = 20
      CCCD_NOTIFY = "\x01\x00"

      def initialize(port:, rx_handle:, tx_handle:, cccd_handle:, ticker:, on_packet:, on_rx:, clock:, log:, drb:)
        @port        = port
        @rx_handle   = rx_handle
        @tx_handle   = tx_handle
        @cccd_handle = cccd_handle
        @ticker      = ticker
        @on_packet   = on_packet
        @on_rx       = on_rx
        @clock       = clock
        @log         = log
        @drb         = drb
        @notify_enabled = false
        @rx_at = nil
      end

      def tick
        event = @port.pop_event(timeout_ms: TICK_MS)
        @port.event_popped
        @on_packet.call(event) if event.is_a?(String)
        poll_cccd
        drain_rx
        @drb.service(@port)
        @ticker.tick(@clock.call / 1000)
      end

      def pump
        @port.event_popped
        event = @port.pop_event(timeout_ms: 0)
        @on_packet.call(event) if event.is_a?(String)
      end

      def write(frame)
        unless @notify_enabled
          @rx_at = nil
          return
        end
        @port.send_notification(@tx_handle, frame)
        stamp_ack
      end

      def disconnected
        @notify_enabled = false
        @rx_at = nil
        @drb.disconnected
      end

      private

      def poll_cccd
        cccd = @port.take_write(@cccd_handle)
        return unless cccd
        @notify_enabled = (cccd == CCCD_NOTIFY)
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

      def stamp_ack
        return unless @rx_at
        ack_at = @clock.call
        @log.call("[t] rx=#{@rx_at} ack=#{ack_at} d=#{ack_at - @rx_at}")
        @rx_at = nil
      end
    end
  end
end
