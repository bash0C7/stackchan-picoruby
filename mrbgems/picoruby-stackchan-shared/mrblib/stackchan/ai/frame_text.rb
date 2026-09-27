module Stackchan
  module AI
    module FrameText
      MAX_CHARS = 19

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

      def self.build(face_index:, text:)
        body = sanitize(text)[0, MAX_CHARS]
        face_index.nil? ? "<text:#{body}>\n" : "<F:#{face_index},text:#{body}>\n"
      end
    end
  end
end
