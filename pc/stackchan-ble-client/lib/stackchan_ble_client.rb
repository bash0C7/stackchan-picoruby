require_relative "stackchan_ble_client/version"
require_relative "stackchan_ble_client/face_table"
require_relative "stackchan_ble_client/led_color_table"
require_relative "stackchan_ble_client/hsb_to_rgb"
require_relative "stackchan_ble_client/frame_codec"
require_relative "stackchan_ble_client/send_builder"
require_relative "stackchan_ble_client/client"
require_relative "stackchan_ble_client/calibration"
require_relative "stackchan_ble_client/throughput_meter"

module StackchanBleClient
  class Error < StandardError; end
  class TimeoutError < Error; end
  class DeviceError < Error; end
  class ConnectionError < Error; end
end
