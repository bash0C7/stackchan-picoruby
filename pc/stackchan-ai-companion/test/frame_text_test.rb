require "test_helper"
require "stackchan_ai_companion/frame_text"

class FrameTextTest < Test::Unit::TestCase
  def test_sanitize_replaces_frame_delimiters
    out = StackchanAiCompanion::FrameText.sanitize("a,b<c>d")
    assert_equal false, out.include?(",")
    assert_equal false, out.include?("<")
    assert_equal false, out.include?(">")
  end

  def test_sanitize_keeps_japanese_and_colon
    out = StackchanAiCompanion::FrameText.sanitize("はい：そうです")
    assert_equal "はい：そうです", out
  end

  def test_sanitize_collapses_newlines
    out = StackchanAiCompanion::FrameText.sanitize("line1\nline2\r\nline3")
    assert_equal false, out.include?("\n")
    assert_equal false, out.include?("\r")
  end

  def test_build_frame_wraps_face_and_text
    frame = StackchanAiCompanion::FrameText.build(face_index: 1, text: "やあ")
    assert_equal "<F:1,text:やあ>\n", frame
  end

  def test_build_frame_text_only
    frame = StackchanAiCompanion::FrameText.build(face_index: nil, text: "やあ")
    assert_equal "<text:やあ>\n", frame
  end

  def test_build_truncates_to_max_chars
    frame = StackchanAiCompanion::FrameText.build(face_index: nil, text: "あ" * 50)
    body = frame[/<text:(.*)>/, 1]
    assert body.length <= StackchanAiCompanion::FrameText::MAX_CHARS
  end
end
