class TextDispatchTest < Picotest::Test
  class NullSink
    def write(_frame); end
  end

  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @dispatcher = RobotTables.dispatcher(
      display: @display, led: @led, stdout: NullSink.new
    )
  end

  def names; @display.calls.map(&:first); end

  def test_handle_text_clears_band_then_draws_text
    @dispatcher.handle({ "text" => "こんにちは" })
    clear = @display.calls.find { |c| c.first == :draw_rect }
    assert(clear)
    _x, y, _w, _h, _color, opts = clear.last
    assert_equal StackChan::Robot::Dispatcher::SUBTITLE_BAND_Y, y
    assert_equal true, opts[:fill]
    txt = @display.calls.find { |c| c.first == :draw_text }
    assert(txt)
    assert_equal "こんにちは", txt.last[2]
  end

  def test_handle_text_with_a_face_draws_the_text_and_the_eyes
    @dispatcher.handle({ "F" => "1", "text" => "やあ" })
    assert(names.include?(:draw_text))
    assert(@display.calls.any? { |c| c.first == :draw_ellipse })
  end

  def test_handle_text_truncates_to_band_capacity
    long = "あ" * 50
    @dispatcher.handle({ "text" => long })
    txt = @display.calls.find { |c| c.first == :draw_text }
    assert_equal("あ" * StackChan::Robot::Dispatcher::SUBTITLE_MAX_CHARS, txt.last[2])
  end

  def test_face_draw_clears_only_face_region_not_band
    StackChan::Robot::Face.new.draw(@display)
    assert_false(@display.calls.any? { |c| c.first == :fill })
    clear = @display.calls.find { |c| c.first == :draw_rect && c.last[1] == 0 }
    assert(clear)
    _x, _y, _w, h, _color, opts = clear.last
    assert_equal true, opts[:fill]
    assert(h <= StackChan::Robot::Dispatcher::SUBTITLE_BAND_Y)
  end
end
