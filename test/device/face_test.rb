class FaceNeutralTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_neutral_draw_sequence
    StackChan::Robot::Face::Neutral.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:draw_rect, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end
end

class FaceSadTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_sad_delta_y_is_negative_eight
    assert_equal(-8, StackChan::Robot::Face::Sad::DELTA_Y)
  end

  def test_sad_corners_droop_below_center
    StackChan::Robot::Face::Sad.new.draw_mouth(@display)
    assert_equal [135, 148, 160, 140, ILI9342::Color::WHITE], @display.calls[0].last
    assert_equal [160, 140, 185, 148, ILI9342::Color::WHITE], @display.calls[1].last
  end
end

class FaceAngryTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_brow_constants
    assert_equal 18, StackChan::Robot::Face::BROW_OFFSET_Y
    assert_equal 16, StackChan::Robot::Face::BROW_HALF_LENGTH
    assert_equal 8,  StackChan::Robot::Face::BROW_INNER_DROP
  end

  def test_angry_draw_sequence
    StackChan::Robot::Face::Angry.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:draw_rect, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end
end

class FaceClosedTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_closed_face_clears_the_face_region_first_then_draws_two_eye_lines_and_no_ellipse
    StackChan::Robot::Face::Closed.new.draw(@display)
    assert_equal :draw_rect, @display.calls.first[0]
    assert_false(@display.calls.any? { |c| c[0] == :draw_ellipse })
    line_calls = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 2, line_calls.length
  end
end

class BaseRedrawEyesClosedTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_base_redraw_eyes_closed_clears_each_eye_region_and_draws_two_eye_lines_without_a_fill
    base = StackChan::Robot::Face::Base.new
    base.redraw_eyes_closed(@display)
    assert_false(@display.calls.any? { |c| c[0] == :fill })
    rect_calls = @display.calls.select { |c| c[0] == :draw_rect }
    line_calls = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 2, rect_calls.length
    assert_equal 2, line_calls.length
  end
end

class FaceFeatureBandsTest < Picotest::Test
  FACES = [
    StackChan::Robot::Face::Neutral, StackChan::Robot::Face::Smile,
    StackChan::Robot::Face::Joy,     StackChan::Robot::Face::Surprised,
    StackChan::Robot::Face::Sad,     StackChan::Robot::Face::Angry,
    StackChan::Robot::Face::Closed,
  ]

  def bands
    f = StackChan::Robot::Face
    [[f::EYE_BAND_X,   f::EYE_BAND_Y,   f::EYE_BAND_W,   f::EYE_BAND_H],
     [f::MOUTH_BAND_X, f::MOUTH_BAND_Y, f::MOUTH_BAND_W, f::MOUTH_BAND_H]]
  end

  def box(call)
    kind, a = call
    case kind
    when :draw_ellipse then [a[0] - a[2], a[1] - a[3], a[0] + a[2], a[1] + a[3]]
    when :draw_line    then [[a[0], a[2]].min, [a[1], a[3]].min, [a[0], a[2]].max, [a[1], a[3]].max]
    when :draw_rect    then [a[0], a[1], a[0] + a[2] - 1, a[1] + a[3] - 1]
    end
  end

  def inside_a_band?(b)
    bands.each do |x, y, w, h|
      return true if b[0] >= x && b[1] >= y && b[2] <= x + w - 1 && b[3] <= y + h - 1
    end
    false
  end

  def test_every_face_paints_only_inside_the_bands_redraw_clears
    FACES.each do |face_class|
      display = FakeDisplay.new
      face_class.new.draw_features(display)
      display.calls.each do |call|
        b = box(call)
        assert_true inside_a_band?(b)
      end
    end
  end

  def test_redraw_clears_both_bands_before_painting
    display = FakeDisplay.new
    StackChan::Robot::Face::Angry.new.redraw(display)
    cleared = display.calls[0, 2].map { |c| c.last[0, 4] }
    assert_equal bands, cleared
  end
end
