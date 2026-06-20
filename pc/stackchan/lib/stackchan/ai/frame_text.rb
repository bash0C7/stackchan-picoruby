module Stackchan::AI
  module FrameText
    MAX_CHARS = 19  # matches device Dispatcher::SUBTITLE_MAX_CHARS

    # Neutralize chars that collide with the <key:val,...>\n frame protocol.
    # The value/pair delimiters (, < >) get full-width substitutes that stay
    # readable in Japanese; CR/LF (the frame terminator) collapse to a space so
    # an FM reply containing a newline can never split or truncate the wire frame.
    def self.sanitize(text)
      text.gsub(",", "、").gsub("<", "＜").gsub(">", "＞").gsub(/[\r\n]+/, " ")
    end

    # Build a single combo frame: optional face index + the sanitized,
    # truncated subtitle text. Wire format: "<F:n,text:...>\n" or "<text:...>\n".
    def self.build(face_index:, text:)
      body = sanitize(text)[0, MAX_CHARS]
      pairs = []
      pairs << "F:#{face_index}" unless face_index.nil?
      pairs << "text:#{body}"
      "<" + pairs.join(",") + ">\n"
    end
  end
end
