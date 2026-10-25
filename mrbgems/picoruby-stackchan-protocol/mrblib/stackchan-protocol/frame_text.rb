# Top-level namespace for StackChan protocol modules.
module Stackchan
  # Namespace for AI-generated text frames.
  module AI
    # Builds the "<text:...>" frame that shows a caption on the robot.
    # Text is sanitized so it cannot break frame syntax.
    module FrameText
      MAX_CHARS = 19

      # Replaces ",", "<" and ">" with full-width characters and collapses a CR/LF run into one space.
      #: (String text) -> String
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

      # Returns the text frame for the sanitized text cut to MAX_CHARS, with a face index when given.
      #: (face_index: Integer?, text: String) -> String
      def self.build(face_index:, text:)
        body = sanitize(text)[0, MAX_CHARS]
        face_index.nil? ? "<text:#{body}>\n" : "<F:#{face_index},text:#{body}>\n"
      end
    end
  end
end
