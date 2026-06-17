module StackchanNotifier
  # Parse an FM reply that begins with a deterministic emotion tag the persona
  # was instructed to emit, e.g. "[joy]やあ". Maps the tag to a device face
  # index (mirrors the device FACE_TABLE / companion EMOTION_FACE). A missing
  # or unknown tag falls back to a caller-supplied face so a non-deterministic
  # FM output can never break rendering.
  module EmotionTag
    TAG_FACE = {
      "neutral"   => 0,
      "smile"     => 1,
      "joy"       => 2,
      "surprised" => 3,
      "sad"       => 4,
      "angry"     => 5,
    }.freeze

    TAG_RE = /\A\s*\[(\w+)\]\s*/

    # Returns [face_index, text_without_tag].
    def self.parse(reply, fallback_face: 0)
      m = reply.match(TAG_RE)
      if m && TAG_FACE.key?(m[1])
        [TAG_FACE[m[1]], reply.sub(TAG_RE, "")]
      else
        [fallback_face, reply]
      end
    end
  end
end
