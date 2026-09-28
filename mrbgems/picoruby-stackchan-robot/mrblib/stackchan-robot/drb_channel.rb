module StackChan
  class Robot
    class DrbChannel
      def initialize(rx_handle:, tx_handle:, cccd_handle:, responder:)
        @rx_handle   = rx_handle
        @tx_handle   = tx_handle
        @cccd_handle = cccd_handle
        @responder   = responder
        @notify = false
      end

      def service(port)
        cccd = port.take_write(@cccd_handle)
        active = !cccd.nil?
        if cccd
          @notify = (cccd == LinkLoop::CCCD_NOTIFY)
          @responder.reset unless @notify
        end
        while (data = port.take_write(@rx_handle))
          active = true
          chunks = DRbBle.chunks(@responder.feed(data))
          i = 0
          while @notify && i < chunks.size
            port.send_notification(@tx_handle, chunks[i])
            i += 1
          end
        end
        active
      end

      def disconnected
        @notify = false
        @responder.reset
      end
    end
  end
end
