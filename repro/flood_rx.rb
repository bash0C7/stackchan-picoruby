# flood_rx.rb
#
# BLE central side of the picoruby-ble cross-thread heap-corruption repro.
# Connects to the "BleRaceRepro" peripheral (ble_race_peripheral.rb) and floods
# write-without-response to its NUS RX characteristic as fast as the link
# allows. This drives BLE_write_data on the peripheral's BTstack task at a high
# rate, racing the peripheral's Ruby VM allocator on the main task.
#
# This particular driver uses rb-corebluetooth-mac (macOS). Any BLE central that
# can flood write-without-response works (nRF Connect "write" loop, bleak, a
# second Pico W, etc.) — the repro does not depend on this specific central.
#
# Run from a context where the `corebluetooth_mac` gem is available, e.g.:
#   cd pc/stackchan && bundle exec ruby ../../repro/flood_rx.rb
# (rb-corebluetooth-mac must be compiled: cd ../rb-corebluetooth-mac &&
#  bundle install && bundle exec rake compile)

require "corebluetooth_mac"

RX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e" # NUS RX
NAME_PREFIX = "BleRaceRepro"
PAYLOAD = "A" * 180     # ~ a typical write-without-response chunk
BURST   = 500           # writes per loop turn

central = CoreBluetoothMac::Central.new
dev = central.scan(timeout: 10).find { |d| d.name&.start_with?(NAME_PREFIX) }
abort "no '#{NAME_PREFIX}' device advertising" unless dev

peripheral = central.connect(dev, timeout: 5)
peripheral.discover_services(timeout: 5)
peripheral.services.each do |s|
  s.discover_characteristics(timeout: 5) if s.respond_to?(:discover_characteristics)
end
rx = peripheral.find_characteristic(RX_UUID) or abort "RX characteristic not found"

puts "connected; flooding write-without-response to RX (Ctrl-C to stop)..."
total = 0
loop do
  BURST.times { rx.write_without_response(PAYLOAD) }
  total += BURST
  $stderr.puts "wrote #{total} chunks (#{total * PAYLOAD.bytesize} bytes)" if total % 5000 == 0
  sleep 0.002 # let CoreBluetooth drain its write queue; remove for max rate
end
