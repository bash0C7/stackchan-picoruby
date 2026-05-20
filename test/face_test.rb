$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class FaceNeutralTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_neutral_draw_sequence
    StackchanApp::Face::Neutral.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end
end

class FaceSadTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_sad_delta_y_is_negative_eight
    assert_equal(-8, StackchanApp::Face::Sad::DELTA_Y)
  end

  def test_sad_corners_droop_below_center
    StackchanApp::Face::Sad.new.draw_mouth(@display)
    assert_equal [135, 148, 160, 140, ILI9342::Color::WHITE], @display.calls[0].last
    assert_equal [160, 140, 185, 148, ILI9342::Color::WHITE], @display.calls[1].last
  end
end

class FaceAngryTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_brow_constants
    assert_equal 18, StackchanApp::Face::BROW_OFFSET_Y
    assert_equal 16, StackchanApp::Face::BROW_HALF_LENGTH
    assert_equal 8,  StackchanApp::Face::BROW_INNER_DROP
  end

  def test_angry_draw_sequence
    StackchanApp::Face::Angry.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end
end

class FaceClosedTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_closed_face_draws_background_fill_and_horizontal_eyes_no_mouth
    StackchanApp::Face::Closed.new.draw(@display)
    # First call: full background fill
    assert_equal :fill, @display.calls.first[0]
    # No draw_ellipse (open eyes) calls
    refute(@display.calls.any? { |c| c[0] == :draw_ellipse },
           "Closed face must not draw open ellipses")
    # Two draw_line calls for the horizontal closed eyes
    line_calls = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 2, line_calls.length, "Closed face must draw exactly 2 lines (eyes only, no mouth)"
  end
end

class BaseRedrawEyesClosedTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_base_redraw_eyes_closed_does_eye_only_update
    base = StackchanApp::Face::Base.new
    base.redraw_eyes_closed(@display)
    # No full-screen fill
    refute(@display.calls.any? { |c| c[0] == :fill },
           "redraw_eyes_closed must NOT do full-screen fill")
    # clear_eye_region's draw_rect calls (2: one per eye region) + 2 draw_line eyes
    rect_calls = @display.calls.select { |c| c[0] == :draw_rect }
    line_calls = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 2, rect_calls.length
    assert_equal 2, line_calls.length
  end
end
