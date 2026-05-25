require_relative "face_table"

module StackchanBleClient
  module FrameCodec
    # API symbol :left / :right are from StackChan's own perspective
    # (its left hand / right hand). The device firmware's wire chars
    # are wired in the opposite direction, so the API translates:
    #   :left  → "R" on the wire (StackChan's left hand)
    #   :right → "L" on the wire (StackChan's right hand)
    # Verified on real hardware 2026-05-17. Keep callers in StackChan
    # perspective and let this table absorb the wire-level reversal.
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

    module_function

    def encode_face(face_name:)
      index = FaceTable::FACE_INDICES.fetch(face_name)
      encode_pairs("F" => index)
    end

    def encode_led(r:, g:, b:, side:, mode:)
      side_char = SIDE_TO_CHAR.fetch(side) { raise ArgumentError, "unknown side: #{side.inspect}" }
      mode_char = MODE_TO_CHAR.fetch(mode) { raise ArgumentError, "unknown mode: #{mode.inspect}" }
      encode_pairs("L" => "1", "R" => r.to_s, "G" => g.to_s, "B" => b.to_s, "S" => side_char, "M" => mode_char)
    end

    def encode_head(yaw_left:, yaw_right:, pitch_up:, time_ms:, velocity:)
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

    def encode_torque(on:)
      encode_pairs("torque" => (on ? "on" : "off"))
    end

    def encode_selftest
      encode_pairs("selftest" => "run")
    end

    def encode_read_pos
      encode_pairs("read" => "pos")
    end

    def parse_ack(frame)
      # frame[0, 1] is safe on a bare 1-char ACK byte too — returns the same char.
      case frame[0, 1]
      when ACK_OK    then :ok
      when ACK_ERROR then :error
      else
        raise ArgumentError, "unknown ack frame: #{frame.inspect}"
      end
    end

    def encode_pairs(pairs)
      "<" + pairs.map { |k, v| "#{k}:#{v}" }.join(",") + ">\n"
    end
  end
end
