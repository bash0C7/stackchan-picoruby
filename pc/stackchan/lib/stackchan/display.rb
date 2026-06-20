# frozen_string_literal: true

require_relative "ble"

module Stackchan
  module Display
    # High-level wrapper over Stackchan::BLE::Client#send for the
    # face / LED / servo / torque / selftest verbs. The underlying
    # SendBuilder + frame_codec handle wire encoding, ACK waiting,
    # and detail-frame capture; this class just exposes a verb-friendly
    # API the daemon and CLI dispatch into.
    class Controller
      def initialize(ble_client)
        @ble = ble_client
      end

      def face(name)
        @ble.send { |s| s.face(name.to_sym) }
      end

      # color: a named symbol (:red/:green/...) or a [:rgb, 0xRRGGBB] / [:hsb, 0xHHSSBB] pair.
      # mode: :solid / :blink / :breathing / :off
      # side: :left / :right / :both (StackChan's own perspective; SIDE_TO_CHAR reverses on the wire)
      def led(side:, color:, mode:)
        form, value = color.is_a?(Array) ? color : [color, nil]
        @ble.send { |s| s.led(form, value, side: side.to_sym, mode: mode.to_sym) }
      end

      def servo(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
        @ble.send do |s|
          s.head(
            yaw_left:  yaw_left,
            yaw_right: yaw_right,
            pitch_up:  pitch_up,
            time_ms:   time_ms,
            velocity:  velocity,
          )
        end
        @ble.last_detail_frame
      end

      def torque(on)
        @ble.send { |s| s.torque(on: on) }
      end

      def selftest
        @ble.send { |s| s.selftest }
      end
    end
  end
end
