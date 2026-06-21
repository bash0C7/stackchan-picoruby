MRuby::Gem::Specification.new('picoruby-ble-bridge') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Thread-safe inbound-BLE bridge for PicoRuby on ESP32: copies GATT-write bytes off the BTstack task into a C FIFO so the mruby String is built on the main task. Contains the StackChan audio-streaming reboot workaround entirely outside the picoruby-ble fork (linker --wrap of BLE_write_data lives in ports/esp32).'
end
