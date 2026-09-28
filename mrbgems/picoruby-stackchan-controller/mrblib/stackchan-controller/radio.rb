module StackChan
  class Controller
    class Radio < BLE
      attr_reader :target, :conn_handle
      attr_accessor :on_notification

      def initialize(name_prefix:)
        @name_prefix    = name_prefix
        @target         = nil
        @on_notification = nil
        super(:central)
      end

      def pop_and_dispatch
        _event_popped
        event = @event_queue.pop(timeout_ms: 0)
        return nil unless event
        packet_callback(event) if event.is_a?(String)
        event
      end

      def advertising_report_callback(report)
        return if @target
        return unless report.name_include?(@name_prefix)
        @target = report
        connect(report)
      end

      def packet_callback(event_packet)
        super
        return unless event_packet.getbyte(0) == GATT_EVENT_NOTIFICATION
        handle = BLE::Utils.little_endian_to_int16(event_packet.byteslice(4, 1))
        len    = BLE::Utils.little_endian_to_int16(event_packet.byteslice(6, 1))
        cb = @on_notification
        cb.call(handle, event_packet.byteslice(8, len)) if cb
      end

      def connect_and_discover(timeout_ms)
        @target = nil
        @conn_handle = HCI_CON_HANDLE_INVALID
        @services.clear
        scan(timeout_ms: timeout_ms, stop_state: :TC_IDLE)
      end
    end
  end
end
