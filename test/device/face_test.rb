class FaceNeutralTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_neutral_draw_sequence
    StackchanApp::Face::Neutral.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:draw_rect, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end
end

class FaceSadTest < Picotest::Test
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

class FaceAngryTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_brow_constants
    assert_equal 18, StackchanApp::Face::BROW_OFFSET_Y
    assert_equal 16, StackchanApp::Face::BROW_HALF_LENGTH
    assert_equal 8,  StackchanApp::Face::BROW_INNER_DROP
  end

  def test_angry_draw_sequence
    StackchanApp::Face::Angry.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:draw_rect, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end
end

class FaceClosedTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_closed_face_draws_background_fill_and_horizontal_eyes_no_mouth
    StackchanApp::Face::Closed.new.draw(@display)
    # First call: face-region clear (top-anchored rect)
    assert_equal :draw_rect, @display.calls.first[0]
    # No draw_ellipse (open eyes) calls
    assert_false(@display.calls.any? { |c| c[0] == :draw_ellipse })
    # Two draw_line calls for the horizontal closed eyes
    line_calls = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 2, line_calls.length
  end
end

class BaseRedrawEyesClosedTest < Picotest::Test
  def setup; @display = FakeDisplay.new; end

  def test_base_redraw_eyes_closed_does_eye_only_update
    base = StackchanApp::Face::Base.new
    base.redraw_eyes_closed(@display)
    # No full-screen fill
    assert_false(@display.calls.any? { |c| c[0] == :fill })
    # clear_eye_region's draw_rect calls (2: one per eye region) + 2 draw_line eyes
    rect_calls = @display.calls.select { |c| c[0] == :draw_rect }
    line_calls = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 2, rect_calls.length
    assert_equal 2, line_calls.length
  end
end

# The differential path only works if the two bands it clears actually cover
# everything any face draws. If a face reached outside them, switching away
# from it would leave part of the old expression on the panel — and no test
# that only checks draw call order would notice.
class FaceFeatureBandsTest < Picotest::Test
  FACES = [
    StackchanApp::Face::Neutral, StackchanApp::Face::Smile,
    StackchanApp::Face::Joy,     StackchanApp::Face::Surprised,
    StackchanApp::Face::Sad,     StackchanApp::Face::Angry,
    StackchanApp::Face::Closed,
  ]

  def bands
    f = StackchanApp::Face
    [[f::EYE_BAND_X,   f::EYE_BAND_Y,   f::EYE_BAND_W,   f::EYE_BAND_H],
     [f::MOUTH_BAND_X, f::MOUTH_BAND_Y, f::MOUTH_BAND_W, f::MOUTH_BAND_H]]
  end

  # [x0, y0, x1, y1] of one recorded primitive.
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
    StackchanApp::Face::Angry.new.redraw(display)
    cleared = display.calls[0, 2].map { |c| c.last[0, 4] }
    assert_equal bands, cleared
  end
end
