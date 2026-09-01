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
    # One batch call over BLINK_BAND (replaces the old clear_eye_region
    # draw_rect pair) + 2 draw_line eyes
    batch_calls = @display.calls.select { |c| c[0] == :batch }
    line_calls  = @display.calls.select { |c| c[0] == :draw_line }
    assert_equal 1, batch_calls.length
    assert_equal 2, line_calls.length
  end
end

# The differential paths only work if the bands they batch into actually
# cover everything the relevant primitives draw. If a face (or a blink)
# reached outside its band, switching away from it would leave part of the
# old expression on the panel — and no test that only checks draw call order
# would notice.
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

  # redraw now sends the eye and mouth bands as one panel transaction
  # (FACE_BAND_*, their union) instead of clearing each separately, so this
  # replaces the old two-clear assertion: one batch over the union rect, and
  # everything painted after it still lands inside that rect.
  def test_redraw_batches_the_union_band_and_paints_inside_it
    f = StackchanApp::Face
    fx, fy, fw, fh = f::FACE_BAND_X, f::FACE_BAND_Y, f::FACE_BAND_W, f::FACE_BAND_H
    FACES.each do |face_class|
      display = FakeDisplay.new
      face_class.new.redraw(display)
      batch_calls = display.calls.select { |c| c[0] == :batch }
      assert_equal 1, batch_calls.length
      assert_equal [fx, fy, fw, fh], batch_calls[0].last[0, 4]
      display.calls[1..-1].each do |call|
        b = box(call)
        assert_true(b[0] >= fx && b[1] >= fy && b[2] <= fx + fw - 1 && b[3] <= fy + fh - 1)
      end
    end
  end

  # BLINK_BAND_* only pays off if a blink never has to touch anything outside
  # it: draw_eyes must stay fully inside it, and everything else a face draws
  # must be fully inside or fully outside — a primitive straddling its edge
  # would get half-erased the next time a blink repaints only the band.
  def test_every_face_never_straddles_the_blink_band
    f = StackchanApp::Face
    bx, by, bw, bh = f::BLINK_BAND_X, f::BLINK_BAND_Y, f::BLINK_BAND_W, f::BLINK_BAND_H
    bx1 = bx + bw - 1
    by1 = by + bh - 1
    FACES.each do |face_class|
      eyes = FakeDisplay.new
      face_class.new.draw_eyes(eyes)
      eyes.calls.each do |call|
        b = box(call)
        assert_true(b[0] >= bx && b[1] >= by && b[2] <= bx1 && b[3] <= by1)
      end

      features = FakeDisplay.new
      face_class.new.draw_features(features)
      features.calls.each do |call|
        b = box(call)
        inside  = b[0] >= bx && b[1] >= by && b[2] <= bx1 && b[3] <= by1
        outside = b[2] < bx || b[0] > bx1 || b[3] < by || b[1] > by1
        assert_true(inside || outside)
      end
    end
  end

  # redraw_eyes_open/_closed batch BLINK_BAND instead of the old
  # clear_eye_region + draw pair (see BLINK_BAND_*'s comment for the
  # SPI#write-count measurement that motivated it).
  def test_every_face_redraw_eyes_open_and_closed_batch_the_blink_band
    f = StackchanApp::Face
    blink = [f::BLINK_BAND_X, f::BLINK_BAND_Y, f::BLINK_BAND_W, f::BLINK_BAND_H]
    FACES.each do |face_class|
      open_display = FakeDisplay.new
      face_class.new.redraw_eyes_open(open_display)
      open_batches = open_display.calls.select { |c| c[0] == :batch }
      assert_equal 1, open_batches.length
      assert_equal blink, open_batches[0].last[0, 4]

      closed_display = FakeDisplay.new
      face_class.new.redraw_eyes_closed(closed_display)
      closed_batches = closed_display.calls.select { |c| c[0] == :batch }
      assert_equal 1, closed_batches.length
      assert_equal blink, closed_batches[0].last[0, 4]
    end
  end
end
