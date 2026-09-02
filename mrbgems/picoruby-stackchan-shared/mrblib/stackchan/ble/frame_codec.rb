module Stackchan
  module BLE
    module FrameCodec
      # :left / :right are from StackChan's own perspective. The device wire
      # chars run the other way, so this table absorbs the reversal.
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

      TOUCH_RE = /\A<touch:(\d+)>/

      def self.encode_face(face_name:)
        index = FaceTable::FACE_INDICES.fetch(face_name)
        encode_pairs("F" => index)
      end

      def self.encode_led(r:, g:, b:, side:, mode:)
        side_char = SIDE_TO_CHAR.fetch(side) { raise ArgumentError, "unknown side: #{side.inspect}" }
        mode_char = MODE_TO_CHAR.fetch(mode) { raise ArgumentError, "unknown mode: #{mode.inspect}" }
        encode_pairs("L" => "1", "R" => r.to_s, "G" => g.to_s, "B" => b.to_s, "S" => side_char, "M" => mode_char)
      end

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

      def self.encode_torque(on:)
        encode_pairs("torque" => (on ? "on" : "off"))
      end

      def self.encode_selftest
        encode_pairs("selftest" => "run")
      end

      def self.encode_read_pos
        encode_pairs("read" => "pos")
      end

      def self.parse_ack(frame)
        case frame[0, 1]
        when ACK_OK    then :ok
        when ACK_ERROR then :error
        else
          raise ArgumentError, "unknown ack frame: #{frame.inspect}"
        end
      end

      # A device-initiated head-touch event (unsolicited; not a response to a send).
      def self.touch_event?(frame)
        !!(frame =~ TOUCH_RE)
      end

      # Zone index from "<touch:N>", or nil if not a touch frame.
      def self.parse_touch(frame)
        m = frame.match(TOUCH_RE)
        m && m[1].to_i
      end

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
