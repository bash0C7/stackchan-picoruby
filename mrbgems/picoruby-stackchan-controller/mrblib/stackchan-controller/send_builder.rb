module StackChan
  class Controller
    # Collects the frames of one send block, keeping the last frame per kind (face, head, torque, selftest, read_pos, and led per side).
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
      }.freeze #: Hash[color_name, Array[Integer]]
      # @rbs @frames: Hash[untyped, String]

      #
      # @rbs!
      #   type color_name = :red | :green | :blue | :yellow | :cyan | :magenta | :white | :off

      # Builds an empty frame collection.
      #: () -> void
      def initialize
        @frames = {}
      end

      # Records the face frame for the named face and returns it.
      #: (Stackchan::BLE::FrameCodec::face_name name) -> String
      def face(name)
        @frames[:face] = Stackchan::BLE::FrameCodec.encode_face(face_name: name)
      end

      # Records the LED frame for the named color, side and mode and returns it. Raises ArgumentError for an unknown color.
      #: (color_name color, ?side: Stackchan::BLE::FrameCodec::side, ?mode: Stackchan::BLE::FrameCodec::led_mode) -> String
      def led(color, side: :both, mode: :solid)
        r, g, b = LED_COLORS.fetch(color) { raise ArgumentError, "unknown LED color: #{color.inspect}" }
        @frames[[:led, side]] = Stackchan::BLE::FrameCodec.encode_led(r: r, g: g, b: b, side: side, mode: mode)
      end

      # Records the head (servo) frame and returns it; yaw_left and yaw_right are 0..100, time_ms and velocity are exclusive.
      #: (?yaw_left: Integer?, ?yaw_right: Integer?, ?pitch_up: Integer?, ?time_ms: Integer?, ?velocity: Integer?) -> String
      def head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
        @frames[:head] = Stackchan::BLE::FrameCodec.encode_head(yaw_left: yaw_left, yaw_right: yaw_right, pitch_up: pitch_up,
                                                                time_ms: time_ms, velocity: velocity)
      end

      # Records the torque on/off frame and returns it.
      #: (on: bool) -> String
      def torque(on:)
        @frames[:torque] = Stackchan::BLE::FrameCodec.encode_torque(on: on)
      end

      # Records the selftest frame and returns it.
      #: () -> String
      def selftest
        @frames[:selftest] = Stackchan::BLE::FrameCodec.encode_selftest
      end

      # Records the read-position frame and returns it.
      #: () -> String
      def read_pos
        @frames[:read_pos] = Stackchan::BLE::FrameCodec.encode_read_pos
      end

      # Returns the recorded frames in recording order.
      #: () -> Array[String]
      def to_frames
        @frames.values
      end
    end
  end
end
