module Stackchan
  module AI
    module FrameText
      MAX_CHARS = 19  # matches device Dispatcher::SUBTITLE_MAX_CHARS

      # Neutralize chars that collide with the <key:val,...>\n frame protocol:
      # delimiters get full-width substitutes, CR/LF collapse to one space.
      # each_char rather than gsub: PicoRuby's gsub takes a String pattern only,
      # and chained gsub with multibyte replacements truncates the tail.
      def self.sanitize(text)
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

      # One combo frame: optional face index + sanitized, truncated subtitle.
      # Wire format: "<F:n,text:...>\n" or "<text:...>\n".
      def self.build(face_index:, text:)
        body = sanitize(text)[0, MAX_CHARS]
        face_index.nil? ? "<text:#{body}>\n" : "<F:#{face_index},text:#{body}>\n"
      end
    end
  end
end
