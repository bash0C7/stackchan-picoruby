class FrameTextTest < Picotest::Test
  FT = Stackchan::AI::FrameText

  def test_frame_text_neutralizes_delimiters_and_collapses_newlines_to_one_space
    assert_equal "<F:0,text:a、b＜c＞d e>\n", FT.build(face_index: 0, text: "a,b<c>d\ne")
    assert_equal "<text:今日は、＜良い＞天気 ですね>\n",
                 FT.build(face_index: nil, text: "今日は、<良い>天気\nですね")
  end

  def test_frame_text_truncates_multibyte_text_to_19_chars
    assert_equal "<F:1,text:あいうえおかきくけこさしすせそたちつて>\n",
                 FT.build(face_index: 1, text: "あいうえおかきくけこさしすせそたちつてとなにぬ")
  end
end
