$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class TextDispatchTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @sink    = []
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led,
      stdout: Object.new.tap { |o| o.define_singleton_method(:write) { |f| } }
    )
  end

  def names; @display.calls.map(&:first); end

  def test_handle_text_clears_band_then_draws_text
    @dispatcher.handle({ "text" => "こんにちは" })
    # band cleared with a filled rect at the subtitle Y, then text drawn.
    clear = @display.calls.find { |c| c.first == :draw_rect }
    assert clear, "subtitle band must be cleared with a filled rect"
    x, y, w, h, _color, opts = clear.last
    assert_equal StackchanApp::Dispatcher::SUBTITLE_BAND_Y, y
    assert_equal true, opts[:fill]
    txt = @display.calls.find { |c| c.first == :draw_text }
    assert txt, "text must be drawn"
    assert_equal "こんにちは", txt.last[2]
  end

  def test_handle_text_is_combinable_with_face
    @dispatcher.handle({ "F" => "1", "text" => "やあ" })
    assert_includes names, :draw_text
    # face draw also happened (fill or draw_rect from Face#draw + eyes)
    assert(@display.calls.any? { |c| c.first == :draw_ellipse },
           "face eyes should be drawn alongside the text")
  end

  def test_handle_text_truncates_to_band_capacity
    long = "あ" * 50
    @dispatcher.handle({ "text" => long })
    txt = @display.calls.find { |c| c.first == :draw_text }
    assert txt.last[2].length <= StackchanApp::Dispatcher::SUBTITLE_MAX_CHARS,
           "text must be truncated to the band's character capacity"
  end

  def test_face_draw_clears_only_face_region_not_band
    StackchanApp::Face::Neutral.new.draw(@display)
    # Must NOT issue a whole-screen fill (which would erase the band).
    assert(@display.calls.none? { |c| c.first == :fill },
           "Face#draw must not full-screen fill (it would erase the subtitle band)")
    clear = @display.calls.find { |c| c.first == :draw_rect && c.last[1] == 0 }
    assert clear, "Face#draw must clear the face region with a top-anchored rect"
    _x, _y, _w, h, _color, opts = clear.last
    assert_equal true, opts[:fill]
    assert h <= StackchanApp::Dispatcher::SUBTITLE_BAND_Y,
           "face-region clear height must not reach into the subtitle band"
  end
end
