require 'test/unit'
require 'tmpdir'
require 'esp_port'

class EspPortTest < Test::Unit::TestCase
  CORES3 = "44:1B:F6:E2:05:64"
  DUALKEY = "10:51:DB:55:78:7C"

  def device(serial, port, loc)
    <<~IOREG
      +-o USB JTAG/serial debug unit@#{loc}  <class IOUSBHostDevice, registered, matched, active>
        {
          "USB Product Name" = "USB JTAG_serial debug unit"
          "USB Serial Number" = "#{serial}"
        }
        +-o IOUSBHostInterface@0
        | {
        |   "USB Serial Number" = "#{serial}"
        | }
        | +-o AppleUSBACMData
        |   +-o IOSerialBSDClient
        |       {
        |         "IOCalloutDevice" = "#{port}"
        |         "IODialinDevice" = "#{port.sub('/cu.', '/tty.')}"
        |       }
    IOREG
  end

  def both = device(DUALKEY, "/dev/cu.usbmodem101", "00100000") + device(CORES3, "/dev/cu.usbmodem1101", "01100000")

  def resolve(ioreg, serial: "", espport: nil) = EspPort.resolve(ioreg_out: ioreg, serial: serial, espport: espport)

  def test_each_board_maps_its_usb_serial_to_its_own_port
    assert_equal [[DUALKEY, "/dev/cu.usbmodem101"], [CORES3, "/dev/cu.usbmodem1101"]], EspPort.devices(both)
  end

  def test_the_serial_picks_the_cores3_even_when_it_sorts_after_another_esp32
    assert_equal "/dev/cu.usbmodem1101", resolve(both, serial: CORES3)
  end

  def test_the_serial_matches_regardless_of_case
    assert_equal "/dev/cu.usbmodem1101", resolve(both, serial: CORES3.downcase)
  end

  def test_two_boards_and_no_serial_stop_instead_of_taking_the_first
    err = assert_raise(EspPort::Error) { resolve(both) }
    assert_include err.message, "2 ESP32-S3 boards"
    assert_include err.message, "#{DUALKEY} at /dev/cu.usbmodem101"
  end

  def test_a_serial_not_on_usb_stops_and_lists_what_is_there
    err = assert_raise(EspPort::Error) { resolve(device(DUALKEY, "/dev/cu.usbmodem101", "00100000"), serial: CORES3) }
    assert_include err.message, "not on USB"
    assert_include err.message, DUALKEY
  end

  def test_an_espport_that_is_another_board_stops
    err = assert_raise(EspPort::Error) { resolve(both, serial: CORES3, espport: "/dev/cu.usbmodem101") }
    assert_include err.message, "is not the CoreS3's port /dev/cu.usbmodem1101"
  end

  def test_an_espport_that_agrees_with_the_serial_passes
    assert_equal "/dev/cu.usbmodem1101", resolve(both, serial: CORES3, espport: "/dev/cu.usbmodem1101")
  end

  def test_a_lone_board_needs_no_serial
    assert_equal "/dev/cu.usbmodem1101", resolve(device(CORES3, "/dev/cu.usbmodem1101", "01100000"))
  end

  def test_no_board_stops
    assert_raise(EspPort::Error) { resolve("") }
  end

  def test_the_serial_comes_from_the_env_before_the_local_file
    Dir.mktmpdir do |root|
      File.write(File.join(root, EspPort::SERIAL_FILE), "#{CORES3}\n")
      assert_equal CORES3, EspPort.serial_from({}, root)
      assert_equal DUALKEY, EspPort.serial_from({ "STACKCHAN_USB_SERIAL" => DUALKEY }, root)
      assert_equal "", EspPort.serial_from({}, File.join(root, "none"))
    end
  end

  def test_a_reset_board_is_found_again_by_its_serial_under_a_new_port
    before = both
    after = device(DUALKEY, "/dev/cu.usbmodem101", "00100000") + device(CORES3, "/dev/cu.usbmodem2101", "02100000")
    serial = EspPort.serial_of(before, "/dev/cu.usbmodem1101")
    assert_equal "/dev/cu.usbmodem2101", EspPort.port_of(after, serial)
  end

  def test_a_board_that_dropped_off_usb_is_not_replaced_by_the_one_left
    only_dualkey = device(DUALKEY, "/dev/cu.usbmodem101", "00100000")
    assert_nil EspPort.port_of(only_dualkey, EspPort.serial_of(both, "/dev/cu.usbmodem1101"))
  end
end
