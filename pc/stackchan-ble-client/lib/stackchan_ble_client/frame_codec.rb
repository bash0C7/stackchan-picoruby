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

    def parse_ack(byte)
      case byte
      when ACK_OK    then :ok
      when ACK_ERROR then :error
      else
        raise ArgumentError, "unknown ack byte: #{byte.inspect}"
      end
    end

    def encode_pairs(pairs)
      "<" + pairs.map { |k, v| "#{k}:#{v}" }.join(",") + ">\n"
    end
  end
end
