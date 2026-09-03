# Protocol-level exceptions shared by every BLE client (StackchanCentral,
# FakeBleClient) and the daemon that rescues them.
module Stackchan
  module BLE
    class Error < StandardError; end
    class TimeoutError < Error; end
    class DeviceError < Error; end
    class ConnectionError < Error; end
  end
end
