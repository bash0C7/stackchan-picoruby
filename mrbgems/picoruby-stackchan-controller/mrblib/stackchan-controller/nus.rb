module StackChan
  class Controller
    module Nus
      def nus_uuid(suffix_hi, suffix_lo)
        [0x6e, 0x40, suffix_hi, suffix_lo,
         0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
         0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
      end

      def rx_uuid; nus_uuid(0x00, 0x02); end
      def tx_uuid; nus_uuid(0x00, 0x03); end
      def drb_rx_uuid; nus_uuid(0x00, 0x04); end
      def drb_tx_uuid; nus_uuid(0x00, 0x05); end

      def cccd_uuid
        [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x10, 0x00,
         0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
      end

      def find_characteristic(services, uuid128)
        services.each do |service|
          found = service[:characteristics].find { |ch| ch[:uuid128] == uuid128 }
          return found if found
        end
        nil
      end

      def cccd_handle(characteristic)
        return nil unless characteristic
        descriptor = characteristic[:descriptors].find { |d| d[:uuid128] == cccd_uuid }
        descriptor && descriptor[:handle]
      end

      def classify(frame)
        return :touch if Stackchan::BLE::FrameCodec.touch_event?(frame)
        head = frame[0, 1]
        return :ack if head == Stackchan::BLE::FrameCodec::ACK_OK || head == Stackchan::BLE::FrameCodec::ACK_ERROR
        :other
      end

      module_function :nus_uuid, :rx_uuid, :tx_uuid, :drb_rx_uuid, :drb_tx_uuid, :cccd_uuid,
                      :find_characteristic, :cccd_handle, :classify
    end
  end
end
