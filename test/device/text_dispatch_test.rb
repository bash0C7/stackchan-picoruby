# Subtitle-band text dispatch. StackchanApp::Dispatcher + Face are inlined into
# app/application.rb; the picotest harness extracts and loads them onto the host
# picoruby VM. Display access is stubbed with FakeDisplay.
class TextDispatchTest < Picotest::Test
  # Minimal AckSink: Dispatcher writes ACK/ERROR frames here; this test ignores them.
  class NullSink
    def write(_frame); end
  end

  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: NullSink.new
    )
  end

  def names; @display.calls.map(&:first); end

  def test_handle_text_clears_band_then_draws_text
    @dispatcher.handle({ "text" => "こんにちは" })
    # band cleared with a filled rect at the subtitle Y, then text drawn.
    clear = @display.calls.find { |c| c.first == :draw_rect }
    assert(clear)
    _x, y, _w, _h, _color, opts = clear.last
    assert_equal StackchanApp::Dispatcher::SUBTITLE_BAND_Y, y
    assert_equal true, opts[:fill]
    txt = @display.calls.find { |c| c.first == :draw_text }
    assert(txt)
    assert_equal "こんにちは", txt.last[2]
  end

  def test_handle_text_is_combinable_with_face
    @dispatcher.handle({ "F" => "1", "text" => "やあ" })
    assert(names.include?(:draw_text))
    # face draw also happened (eyes drawn alongside the text).
    assert(@display.calls.any? { |c| c.first == :draw_ellipse })
  end

  def test_handle_text_truncates_to_band_capacity
    long = "あ" * 50
    @dispatcher.handle({ "text" => long })
    txt = @display.calls.find { |c| c.first == :draw_text }
    # Truncated to the band's character capacity (SUBTITLE_MAX_CHARS glyphs).
    # String#length on a sliced multibyte string is unreliable on picoruby, so
    # assert the exact truncated value by byte-equality instead of by length.
    assert_equal("あ" * StackchanApp::Dispatcher::SUBTITLE_MAX_CHARS, txt.last[2])
  end

  def test_face_draw_clears_only_face_region_not_band
    StackchanApp::Face::Neutral.new.draw(@display)
    # Must NOT issue a whole-screen fill (which would erase the band).
    assert_false(@display.calls.any? { |c| c.first == :fill })
    clear = @display.calls.find { |c| c.first == :draw_rect && c.last[1] == 0 }
    assert(clear)
    _x, _y, _w, h, _color, opts = clear.last
    assert_equal true, opts[:fill]
    # face-region clear height must not reach into the subtitle band.
    assert(h <= StackchanApp::Dispatcher::SUBTITLE_BAND_Y)
  end
end
