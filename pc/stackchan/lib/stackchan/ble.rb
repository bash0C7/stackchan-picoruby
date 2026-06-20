# frozen_string_literal: true

require_relative "../stackchan"

module Stackchan
  module BLE
    class Error < StandardError; end
    class TimeoutError < Error; end
    class DeviceError < Error; end
    class ConnectionError < Error; end
  end
end

require_relative "ble/face_table"
require_relative "ble/led_color_table"
require_relative "ble/hsb_to_rgb"
require_relative "ble/frame_codec"
require_relative "ble/send_builder"
require_relative "ble/client"
require_relative "ble/calibration"
require_relative "ble/throughput_meter"
