module StackChan
  class Controller
    class SendBuilder
      LED_COLORS = {
        red:     [255, 0,   0],
        green:   [0,   255, 0],
        blue:    [0,   0,   255],
        yellow:  [255, 255, 0],
        cyan:    [0,   255, 255],
        magenta: [255, 0,   255],
        white:   [255, 255, 255],
        off:     [0,   0,   0],
      }.freeze

      def initialize
        @frames = {}
      end

      def face(name)
        @frames[:face] = Stackchan::BLE::FrameCodec.encode_face(face_name: name)
      end

      def led(color, side: :both, mode: :solid)
        r, g, b = LED_COLORS.fetch(color) { raise ArgumentError, "unknown LED color: #{color.inspect}" }
        @frames[[:led, side]] = Stackchan::BLE::FrameCodec.encode_led(r: r, g: g, b: b, side: side, mode: mode)
      end

      def head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
        @frames[:head] = Stackchan::BLE::FrameCodec.encode_head(yaw_left: yaw_left, yaw_right: yaw_right, pitch_up: pitch_up,
                                                                time_ms: time_ms, velocity: velocity)
      end

      def torque(on:)
        @frames[:torque] = Stackchan::BLE::FrameCodec.encode_torque(on: on)
      end

      def selftest
        @frames[:selftest] = Stackchan::BLE::FrameCodec.encode_selftest
      end

      def read_pos
        @frames[:read_pos] = Stackchan::BLE::FrameCodec.encode_read_pos
      end

      def to_frames
        @frames.values
      end
    end
  end
end
