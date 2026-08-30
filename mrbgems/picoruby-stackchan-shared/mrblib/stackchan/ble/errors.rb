# Protocol-level exceptions shared by every BLE client (real StackchanCentral,
# FakeBleClient) and the daemon that rescues them. Lives in the shared gem so
# a client can be loaded and tested without the daemon.
module Stackchan::BLE
  class Error < StandardError; end
  class TimeoutError < Error; end
  class DeviceError < Error; end
  class ConnectionError < Error; end
end
