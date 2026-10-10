module StackChan
  class Controller
    module Nus
      def nus_uuid(suffix_hi, suffix_lo)
        [0x6e, 0x40, suffix_hi, suffix_lo,
         0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
         0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
      end

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

      HEX = "0123456789abcdef"
      GAP_BASE_SUFFIX = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")

      def hex_bytes(uuid128, from, count)
        out = ""
        i = from
        while i < from + count
          b = uuid128.getbyte(i)
          out << HEX[b >> 4, 1] << HEX[b & 0x0f, 1]
          i += 1
        end
        out
      end

      def short_uuid(uuid128)
        return "?" unless uuid128.is_a?(String) && uuid128.bytesize == 16
        if uuid128.byteslice(4, 12) == GAP_BASE_SUFFIX
          hex_bytes(uuid128, 2, 2)
        else
          hex_bytes(uuid128, 0, 4)
        end
      end

      def describe_services(services)
        shorts = []
        services.each do |service|
          service[:characteristics].each { |ch| shorts << short_uuid(ch[:uuid128]) }
        end
        "discovered services=#{services.size} characteristics=#{shorts.empty? ? "none" : shorts.join(",")}"
      end

      module_function :nus_uuid, :drb_rx_uuid, :drb_tx_uuid, :cccd_uuid,
                      :find_characteristic, :cccd_handle,
                      :hex_bytes, :short_uuid, :describe_services
    end
  end
end
