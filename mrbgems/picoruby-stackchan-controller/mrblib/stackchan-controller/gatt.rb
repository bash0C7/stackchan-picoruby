module StackChan
  class Controller
    # GATT UUID helpers for the dRuby pair and the CCCD descriptor; every method is also a module function.
    module Gatt
      # Returns the 16-byte 128-bit UUID in the Nordic UART base with the given two suffix bytes.
      #: (Integer suffix_hi, Integer suffix_lo) -> String
      def base_uuid(suffix_hi, suffix_lo)
        [0x6e, 0x40, suffix_hi, suffix_lo,
         0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
         0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
      end

      # Returns the 128-bit UUID of the dRuby write characteristic (6e400004).
      #: () -> String
      def drb_rx_uuid; base_uuid(0x00, 0x04); end
      # Returns the 128-bit UUID of the dRuby notify characteristic (6e400005).
      #: () -> String
      def drb_tx_uuid; base_uuid(0x00, 0x05); end

      # Returns the 128-bit UUID of the Client Characteristic Configuration descriptor (0x2902).
      #: () -> String
      def cccd_uuid
        [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x10, 0x00,
         0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
      end

      # Returns the first characteristic whose uuid128 matches across all services, or nil.
      #: (Array[Hash[Symbol, untyped]] services, String uuid128) -> Hash[Symbol, untyped]?
      def find_characteristic(services, uuid128)
        services.each do |service|
          found = service[:characteristics].find { |ch| ch[:uuid128] == uuid128 }
          return found if found
        end
        nil
      end

      # Returns the handle of the CCCD descriptor of the characteristic, or nil when there is none.
      #: (Hash[Symbol, untyped]? characteristic) -> Integer?
      def cccd_handle(characteristic)
        return nil unless characteristic
        descriptor = characteristic[:descriptors].find { |d| d[:uuid128] == cccd_uuid }
        descriptor && descriptor[:handle]
      end

      HEX = "0123456789abcdef"
      GAP_BASE_SUFFIX = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")

      # Returns count bytes of uuid128 starting at index from as lowercase hex.
      #: (String uuid128, Integer from, Integer count) -> String
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

      # Returns the short hex form of a 128-bit UUID (4 digits on the Bluetooth base, 8 digits otherwise), or "?" for a non-UUID.
      #: (untyped uuid128) -> String
      def short_uuid(uuid128)
        return "?" unless uuid128.is_a?(String) && uuid128.bytesize == 16
        if uuid128.byteslice(4, 12) == GAP_BASE_SUFFIX
          hex_bytes(uuid128, 2, 2)
        else
          hex_bytes(uuid128, 0, 4)
        end
      end

      # Returns a one-line summary of the discovered services and the short UUIDs of their characteristics.
      #: (Array[Hash[Symbol, untyped]] services) -> String
      def describe_services(services)
        shorts = []
        services.each do |service|
          service[:characteristics].each { |ch| shorts << short_uuid(ch[:uuid128]) }
        end
        "discovered services=#{services.size} characteristics=#{shorts.empty? ? "none" : shorts.join(",")}"
      end

      module_function :base_uuid, :drb_rx_uuid, :drb_tx_uuid, :cccd_uuid,
                      :find_characteristic, :cccd_handle,
                      :hex_bytes, :short_uuid, :describe_services
    end
  end
end
