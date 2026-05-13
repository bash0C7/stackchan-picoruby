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

  def test_left_eye_at_upstream_coords
    @face.draw_eyes(@display)
    left = @display.calls.first
    assert_equal :draw_ellipse, left.first
    cx, cy, rx, ry, color, opts = left.last
    assert_equal 90,  cx
    assert_equal 104, cy
    assert_equal 16,  rx
    assert_equal 16,  ry
    assert_equal ILI9342::Color::WHITE, color
    assert_equal({ fill: true }, opts)
  end

  def test_right_eye_at_mirrored_coords
    @face.draw_eyes(@display)
    right = @display.calls[1]
    cx, cy, * = right.last
    assert_equal 230, cx
    assert_equal 104, cy
  end
end

class FaceBaseMouthTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @face = StackchanProtocol::Face::Base.new
  end

  def test_draw_mouth_emits_two_lines
    @face.draw_mouth(@display, 0)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal 2, line_calls.size
  end

  def test_delta_y_zero_draws_straight_mouth
    @face.draw_mouth(@display, 0)
    # left segment: (115, 146) -> (160, 146)
    assert_equal [115, 146, 160, 146, ILI9342::Color::WHITE], @display.calls[0].last
    # right segment: (160, 146) -> (205, 146)
    assert_equal [160, 146, 205, 146, ILI9342::Color::WHITE], @display.calls[1].last
  end

  def test_positive_delta_y_lifts_corners
    @face.draw_mouth(@display, 8)
    # corner_y = 146 - 8 = 138
    assert_equal [115, 138, 160, 146, ILI9342::Color::WHITE], @display.calls[0].last
    assert_equal [160, 146, 205, 138, ILI9342::Color::WHITE], @display.calls[1].last
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
    assert_equal [115, 138, 160, 146, ILI9342::Color::WHITE], line_calls.first.last
  end

  def test_joy_uses_delta_y_eighteen_for_mouth
    StackchanProtocol::Face::Joy.new.draw(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal [115, 128, 160, 146, ILI9342::Color::WHITE], line_calls.first.last
  end
end

class DispatcherHandleByteTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @stdout  = FakeStdout.new
    @dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display,
      stdin:   FakeStdin.new(""),
      stdout:  @stdout
    )
  end

  def test_byte_zero_draws_neutral
    @dispatcher.handle_byte("0")
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 146, line[1]
  end

  def test_byte_one_draws_smile
    @dispatcher.handle_byte("1")
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 138, line[1]
  end

  def test_byte_two_draws_joy
    @dispatcher.handle_byte("2")
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 128, line[1]
  end

  def test_valid_byte_does_not_write_error
    @dispatcher.handle_byte("0")
    assert_equal [], @stdout.writes
  end

  def test_unknown_byte_writes_question_mark
    @dispatcher.handle_byte("9")
    assert_equal ["?"], @stdout.writes
  end

  def test_unknown_byte_does_not_draw
    @dispatcher.handle_byte("9")
    assert_equal [], @display.calls
  end

  def test_newline_is_treated_as_unknown
    @dispatcher.handle_byte("\n")
    assert_equal ["?"], @stdout.writes
  end

  def test_carriage_return_is_treated_as_unknown
    @dispatcher.handle_byte("\r")
    assert_equal ["?"], @stdout.writes
  end

  def test_display_failure_emits_error_byte
    @display.raise_on_fill = StandardError.new("simulated draw failure")
    @dispatcher.handle_byte("0")
    assert_equal ["?"], @stdout.writes
  end

  def test_display_failure_does_not_propagate
    @display.raise_on_fill = StandardError.new("simulated draw failure")
    assert_nothing_raised do
      @dispatcher.handle_byte("0")
    end
  end
end
