# Finds the CoreS3 USB port by the board's USB serial number from ioreg output.
module EspPort
  PRODUCT = "USB JTAG/serial debug unit"
  SERIAL_FILE = ".stackchan-usb-serial"

  # Raised when the CoreS3 port cannot be determined unambiguously.
  class Error < StandardError; end

  # @rbs!
  #   interface _Lookup
  #     def []: (String) -> String?
  #   end

  module_function

  # Returns the ioreg listing of ESP32-S3 USB JTAG/serial devices.
  #: () -> String
  def ioreg = `ioreg -w 0 -r -n "#{PRODUCT}" -l 2>/dev/null`

  # Returns [usb_serial, callout_port] pairs found in ioreg output.
  #: (String ioreg_out) -> Array[[String, String]]
  def devices(ioreg_out)
    ioreg_out.split(/^\+-o /).filter_map do |block|
      serial = block[/"USB Serial Number" = "([^"]+)"/, 1]
      port = block[/"IOCalloutDevice" = "([^"]+)"/, 1]
      [serial, port] if serial && port
    end
  end

  # Returns the USB serial of the device on port, or nil.
  #: (String ioreg_out, String port) -> String?
  def serial_of(ioreg_out, port) = devices(ioreg_out).find { |_, p| p == port }&.first

  # Returns the port of the device with this USB serial (case-insensitive), or nil.
  #: (String ioreg_out, String? serial) -> String?
  def port_of(ioreg_out, serial) = devices(ioreg_out).find { |s, _| s.casecmp?(serial.to_s) }&.last

  # Returns the CoreS3 USB serial from STACKCHAN_USB_SERIAL or the .stackchan-usb-serial file under root; empty when neither exists.
  #: (_Lookup env, String root) -> String
  def serial_from(env, root)
    s = env["STACKCHAN_USB_SERIAL"].to_s.strip
    return s unless s.empty?
    file = File.join(root, SERIAL_FILE)
    File.exist?(file) ? File.read(file).strip : ""
  end

  # Returns the CoreS3 port. Raises Error when the board is missing, ambiguous, or disagrees with espport.
  #: (ioreg_out: String, serial: String?, espport: String?) -> String
  def resolve(ioreg_out:, serial:, espport:)
    found = devices(ioreg_out)
    listing = found.empty? ? "none" : found.map { |s, p| "#{s} at #{p}" }.join(", ")
    port =
      if !serial.to_s.empty?
        hit = found.find { |s, _| s.casecmp?(serial) }
        raise Error, "the CoreS3 (USB serial #{serial}) is not on USB; ESP32-S3 boards present: #{listing}" unless hit
        hit[1]
      elsif found.size == 1
        found[0][1]
      elsif found.empty?
        raise Error, "no ESP32-S3 board on USB"
      else
        raise Error, "#{found.size} ESP32-S3 boards on USB (#{listing}); " \
                     "name the CoreS3 with STACKCHAN_USB_SERIAL= or #{SERIAL_FILE}"
      end
    if espport && !espport.empty? && espport != port
      raise Error, "ESPPORT=#{espport} is not the CoreS3's port #{port} (#{listing})"
    end
    port
  end
end
