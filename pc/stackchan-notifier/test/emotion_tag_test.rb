require_relative "helper"
require "stackchan_notifier/emotion_tag"

class EmotionTagTest < Test::Unit::TestCase
  def test_parses_leading_tag_to_face_and_strips_it
    face, text = StackchanNotifier::EmotionTag.parse("[joy]やあ")
    assert_equal 2, face
    assert_equal "やあ", text
  end

  def test_unknown_tag_uses_fallback_and_keeps_text
    face, text = StackchanNotifier::EmotionTag.parse("[grumpy]むむ", fallback_face: 3)
    assert_equal 3, face
    assert_equal "[grumpy]むむ", text
  end

  def test_missing_tag_uses_fallback_and_keeps_text
    face, text = StackchanNotifier::EmotionTag.parse("こんにちは", fallback_face: 1)
    assert_equal 1, face
    assert_equal "こんにちは", text
  end

  def test_tolerates_leading_whitespace_around_tag
    face, text = StackchanNotifier::EmotionTag.parse(" [sad] しょんぼり ")
    assert_equal 4, face
    assert_equal "しょんぼり ", text
  end
end
