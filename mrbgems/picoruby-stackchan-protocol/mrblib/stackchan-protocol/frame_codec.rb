# Top-level namespace for StackChan protocol modules.
module Stackchan
  # Namespace for BLE frame encoding.
  module BLE
    # Encodes face, LED, head, torque and read commands into "<key:value,...>\n" frames
    # and parses touch notifications.
    module FrameCodec
      # @rbs!
      #   type face_name = :neutral | :smile | :joy | :surprised | :sad | :angry
      #   type side = :left | :right | :both
      #   type led_mode = :solid | :blink | :breathing | :off

      FACE_INDICES = {
        neutral:   "0",
        smile:     "1",
        joy:       "2",
        surprised: "3",
        sad:       "4",
        angry:     "5",
      }.freeze

      SIDE_TO_CHAR = {
        left:  "R",
        right: "L",
        both:  "B",
      }.freeze

      MODE_TO_CHAR = {
        solid:     "s",
        blink:     "b",
        breathing: "p",
        off:       "o",
      }.freeze

      ACK_OK    = "."
      ACK_ERROR = "?"

      # Returns the face frame for face_name; raises KeyError for an unknown name.
      #: (face_name: face_name) -> String
      def self.encode_face(face_name:)
        encode_pairs("F" => FACE_INDICES.fetch(face_name))
      end

      # Returns the LED frame for the color, side and mode; raises ArgumentError for an unknown side or mode.
      #: (r: Integer, g: Integer, b: Integer, side: side, mode: led_mode) -> String
      def self.encode_led(r:, g:, b:, side:, mode:)
        side_char = SIDE_TO_CHAR.fetch(side) { raise ArgumentError, "unknown side: #{side.inspect}" }
        mode_char = MODE_TO_CHAR.fetch(mode) { raise ArgumentError, "unknown mode: #{mode.inspect}" }
        encode_pairs("L" => "1", "R" => r.to_s, "G" => g.to_s, "B" => b.to_s, "S" => side_char, "M" => mode_char)
      end

      # Returns the head position frame; nil arguments are omitted and velocity is used only without time_ms.
      # Raises ArgumentError when both yaws are given or none of yaw_left, yaw_right and pitch_up is given.
      #: (yaw_left: Integer?, yaw_right: Integer?, pitch_up: Integer?, time_ms: Integer?, velocity: Integer?) -> String
      def self.encode_head(yaw_left:, yaw_right:, pitch_up:, time_ms:, velocity:)
        if !yaw_left.nil? && !yaw_right.nil?
          raise ArgumentError, "encode_head: yaw_left and yaw_right are mutually exclusive (specify only one)"
        end
        if yaw_left.nil? && yaw_right.nil? && pitch_up.nil?
          raise ArgumentError, "encode_head requires at least one of yaw_left / yaw_right / pitch_up"
        end
        pairs = {}
        pairs["YL"] = yaw_left.to_s  unless yaw_left.nil?
        pairs["YR"] = yaw_right.to_s unless yaw_right.nil?
        pairs["PU"] = pitch_up.to_s  unless pitch_up.nil?
        pairs["T"]  = time_ms.to_s   if time_ms
        pairs["V"]  = velocity.to_s  if velocity && !time_ms
        encode_pairs(pairs)
      end

      # Returns the servo torque frame, on or off.
      #: (on: bool) -> String
      def self.encode_torque(on:)
        encode_pairs("torque" => (on ? "on" : "off"))
      end

      # Returns the servo self-test frame.
      #: () -> String
      def self.encode_selftest
        encode_pairs("selftest" => "run")
      end

      # Returns the frame that asks for the raw servo positions.
      #: () -> String
      def self.encode_read_pos
        encode_pairs("read" => "pos")
      end

      # Returns true when frame is a "<touch:N>" notification.
      #: (String frame) -> bool
      def self.touch_event?(frame)
        !parse_touch(frame).nil?
      end

      # Returns the zone number of a "<touch:N>" frame, or nil when frame is not one.
      #: (String frame) -> Integer?
      def self.parse_touch(frame)
        prefix = "<touch:"
        return nil unless frame.start_with?(prefix)
        len = frame.length
        i = prefix.length
        digits_start = i
        while i < len && frame.getbyte(i) >= 48 && frame.getbyte(i) <= 57
          i += 1
        end
        return nil if i == digits_start
        return nil unless frame.getbyte(i) == 62
        frame[digits_start...i].to_i
      end

      # Joins the key/value pairs into one "<k:v,k:v>\n" frame.
      #: (Hash[String, String] pairs) -> String
      def self.encode_pairs(pairs)
        body = ""
        pairs.each do |k, v|
          body << "," unless body.empty?
          body << k << ":" << v
        end
        "<" + body + ">\n"
      end
    end
  end
end
