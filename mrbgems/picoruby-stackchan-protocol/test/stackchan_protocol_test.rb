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
