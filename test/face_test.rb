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
