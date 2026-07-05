module Stackchan::AI
  module FrameText
    MAX_CHARS = 19  # matches device Dispatcher::SUBTITLE_MAX_CHARS

    # Neutralize chars that collide with the <key:val,...>\n frame protocol.
    # The value/pair delimiters (, < >) get full-width substitutes that stay
    # readable in Japanese; CR/LF (the frame terminator) collapse to a space so
    # an FM reply containing a newline can never split or truncate the wire frame.
    def self.sanitize(text)
      # Single each_char pass, NO gsub. Two PicoRuby host-VM String bugs force
      # this: (1) gsub takes a String pattern only (no Regexp, so `/[\r\n]+/`
      # is out), and (2) chained gsub with a multibyte replacement truncates
      # the tail once the source already contains a multibyte char before the
      # match — which is exactly the Japanese-FM-text case. each_char is
      # reliable. Output is identical to CRuby's
      # `gsub(",","、").gsub("<","＜").gsub(">","＞").gsub(/[\r\n]+/, " ")`.
      out = ""
      prev_nl = false
      text.each_char do |ch|
        case ch
        when ","
          out << "、"; prev_nl = false
        when "<"
          out << "＜"; prev_nl = false
        when ">"
          out << "＞"; prev_nl = false
        when "\r", "\n"
          out << " " unless prev_nl
          prev_nl = true
        else
          out << ch; prev_nl = false
        end
      end
      out
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
