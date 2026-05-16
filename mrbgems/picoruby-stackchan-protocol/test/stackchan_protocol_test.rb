require "test_helper"

class FakeDisplayHarnessTest < Test::Unit::TestCase
  def test_fill_records_call
    d = FakeDisplay.new
    d.fill(0x0000)
    assert_equal [[:fill, [0x0000]]], d.calls
  end

  def test_draw_ellipse_records_keyword_arg
    d = FakeDisplay.new
    d.draw_ellipse(10, 20, 5, 6, 0xFFFF, fill: true)
    assert_equal [[:draw_ellipse, [10, 20, 5, 6, 0xFFFF, { fill: true }]]], d.calls
  end

  def test_draw_line_records_call
    d = FakeDisplay.new
    d.draw_line(0, 0, 10, 10, 0xFFFF)
    assert_equal [[:draw_line, [0, 0, 10, 10, 0xFFFF]]], d.calls
  end

  def test_fill_raises_when_configured
    d = FakeDisplay.new
    d.raise_on_fill = StandardError.new("boom")
    assert_raises(StandardError) { d.fill(0x0000) }
  end
end

class FakeStdinHarnessTest < Test::Unit::TestCase
  def test_reads_one_byte_at_a_time
    s = FakeStdin.new("abc")
    assert_equal "a", s.read(1)
    assert_equal "b", s.read(1)
    assert_equal "c", s.read(1)
    assert_nil s.read(1)
  end

  def test_rejects_non_one_reads
    s = FakeStdin.new("abc")
    assert_raises(ArgumentError) { s.read(2) }
  end
end

class FakeStdoutHarnessTest < Test::Unit::TestCase
  def test_records_writes
    o = FakeStdout.new
    o.write("?")
    o.write("X")
    assert_equal ["?", "X"], o.writes
  end

  def test_returns_bytesize
    o = FakeStdout.new
    assert_equal 1, o.write("?")
  end
end

class FaceBaseEyesTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @face = StackchanProtocol::Face::Base.new
  end

  def test_draw_eyes_emits_two_filled_ellipses
    @face.draw_eyes(@display)
    ellipse_calls = @display.calls.select { |c| c.first == :draw_ellipse }
    assert_equal 2, ellipse_calls.size, "must draw both eyes"
  end

  def test_left_eye_at_official_ratio_coords
    @face.draw_eyes(@display)
    left = @display.calls.first
    assert_equal :draw_ellipse, left.first
    cx, cy, rx, ry, color, opts = left.last
    assert_equal 110, cx
    assert_equal 100, cy
    assert_equal 4,   rx
    assert_equal 4,   ry
    assert_equal ILI9342::Color::WHITE, color
    assert_equal({ fill: true }, opts)
  end

  def test_right_eye_at_mirrored_coords
    @face.draw_eyes(@display)
    right = @display.calls[1]
    cx, cy, * = right.last
    assert_equal 210, cx
    assert_equal 100, cy
  end
end

class FaceBaseMouthTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
  end

  def test_draw_mouth_emits_two_lines
    StackchanProtocol::Face::Base.new.draw_mouth(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal 2, line_calls.size
  end

  def test_base_delta_y_zero_draws_straight_mouth
    StackchanProtocol::Face::Base.new.draw_mouth(@display)
    # left segment: (135, 140) -> (160, 140)
    assert_equal [135, 140, 160, 140, ILI9342::Color::WHITE], @display.calls[0].last
    # right segment: (160, 140) -> (185, 140)
    assert_equal [160, 140, 185, 140, ILI9342::Color::WHITE], @display.calls[1].last
  end

  def test_smile_class_delta_y_lifts_corners
    StackchanProtocol::Face::Smile.new.draw_mouth(@display)
    # corner_y = 140 - 8 = 132
    assert_equal [135, 132, 160, 140, ILI9342::Color::WHITE], @display.calls[0].last
    assert_equal [160, 140, 185, 132, ILI9342::Color::WHITE], @display.calls[1].last
  end
end

class FaceSurprisedTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
  end

  def test_draw_mouth_emits_filled_rect
    StackchanProtocol::Face::Surprised.new.draw_mouth(@display)
    rect_calls = @display.calls.select { |c| c.first == :draw_rect }
    assert_equal 1, rect_calls.size
    x, y, w, h, color, opts = rect_calls.first.last
    # half_w=6 -> x=160-6=154, w=12; half_h=12 -> y=140-12=128, h=24
    assert_equal 154, x
    assert_equal 128, y
    assert_equal 12,  w
    assert_equal 24,  h
    assert_equal ILI9342::Color::WHITE, color
    assert_equal({ fill: true }, opts)
  end

  def test_draw_sequence_is_fill_then_two_eyes_then_one_rect
    StackchanProtocol::Face::Surprised.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_rect], methods
  end
end

class FaceSubclassesTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
  end

  def test_neutral_delta_y_is_zero
    assert_equal 0, StackchanProtocol::Face::Neutral::DELTA_Y
  end

  def test_smile_delta_y_is_eight
    assert_equal 8, StackchanProtocol::Face::Smile::DELTA_Y
  end

  def test_joy_delta_y_is_eighteen
    assert_equal 18, StackchanProtocol::Face::Joy::DELTA_Y
  end

  def test_draw_starts_with_black_fill
    StackchanProtocol::Face::Neutral.new.draw(@display)
    assert_equal [:fill, [ILI9342::Color::BLACK]], @display.calls.first
  end

  def test_draw_sequence_is_fill_then_two_eyes_then_two_mouth_lines
    StackchanProtocol::Face::Smile.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end

  def test_smile_uses_delta_y_eight_for_mouth
    StackchanProtocol::Face::Smile.new.draw(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal [135, 132, 160, 140, ILI9342::Color::WHITE], line_calls.first.last
  end

  def test_joy_uses_delta_y_eighteen_for_mouth
    StackchanProtocol::Face::Joy.new.draw(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal [135, 122, 160, 140, ILI9342::Color::WHITE], line_calls.first.last
  end
end
