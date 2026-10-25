module StackChan
  class Robot
    # Connects the dRuby GATT pair of a BLE port to a DRbBle::Responder, notifying only after the CCCD enables it.
    class DrbChannel
      # @rbs!
      #   interface _Port
      #     def take_write: (Integer handle) -> String?
      #     def send_notification: (Integer handle, String frame) -> void
      #   end

      # Stores the three attribute handles and the responder; notifications start disabled.
      #: (rx_handle: Integer, tx_handle: Integer, cccd_handle: Integer, responder: DRbBle::Responder) -> void
      def initialize(rx_handle:, tx_handle:, cccd_handle:, responder:)
        @rx_handle   = rx_handle
        @tx_handle   = tx_handle
        @cccd_handle = cccd_handle
        @responder   = responder
        @notify = false
      end

      # Applies a pending CCCD write, feeds received data to the responder and notifies the reply chunks.
      # Returns true when the CCCD or the receive handle had data.
      #: (_Port port) -> bool
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

      # Disables notifications and resets the responder.
      #: () -> void
      def disconnected
        @notify = false
        @responder.reset
      end
    end
  end
end
