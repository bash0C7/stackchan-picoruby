require "test_helper"
require "stackchan_protocol/dispatcher"

class DispatcherFaceTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_F_0_draws_neutral
    @disp.handle({ "F" => "0" })
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end

  def test_F_1_draws_smile
    @disp.handle({ "F" => "1" })
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 132, line[1]
  end

  def test_F_2_draws_joy
    @disp.handle({ "F" => "2" })
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 122, line[1]
  end

  def test_F_3_draws_surprised
    @disp.handle({ "F" => "3" })
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_rect], methods
  end

  def test_F_4_draws_sad
    @disp.handle({ "F" => "4" })
    # Sad call sequence is identical shape to Smile, but corner y is 148 not 132.
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 148, line[1]
  end

  def test_F_5_draws_angry
    @disp.handle({ "F" => "5" })
    methods = @display.calls.map(&:first)
    # fill, 2 eyes, 2 neutral mouth, 2 brow lines
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_F_4_and_F_5_write_ack
    @disp.handle({ "F" => "4" })
    assert_equal ["."], @stdout.writes
    @stdout.writes.clear if @stdout.writes.respond_to?(:clear)
  end

  def test_F_unknown_writes_error
    @disp.handle({ "F" => "9" })
    assert_equal ["?"], @stdout.writes
  end

  def test_F_valid_writes_ack
    @disp.handle({ "F" => "0" })
    assert_equal ["."], @stdout.writes
  end
end

class DispatcherLedTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_L_solid_sends_animate
    @disp.handle({ "L" => "1", "R" => "100", "G" => "200", "B" => "50", "S" => "B", "M" => "s" })
    assert_equal [:both, 100, 200, 50, :solid], @led.last_animate_side_args
  end

  def test_L_blink
    @disp.handle({ "L" => "1", "R" => "255", "G" => "0", "B" => "0", "S" => "B", "M" => "b" })
    assert_equal [:both, 255, 0, 0, :blink], @led.last_animate_side_args
  end

  def test_L_breathing
    @disp.handle({ "L" => "1", "R" => "0", "G" => "255", "B" => "0", "S" => "B", "M" => "p" })
    assert_equal [:both, 0, 255, 0, :breathing], @led.last_animate_side_args
  end

  def test_L_off_no_rgb
    @disp.handle({ "L" => "1", "S" => "B", "M" => "o" })
    assert_equal [:both, 0, 0, 0, :off], @led.last_animate_side_args
  end

  def test_L_unknown_mode_writes_error
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "0", "S" => "B", "M" => "x" })
    assert_equal ["?"], @stdout.writes
    assert_nil @led.last_animate_side_args
  end

  def test_L_valid_writes_ack
    @disp.handle({ "L" => "1", "S" => "B", "M" => "o" })
    assert_equal ["."], @stdout.writes
  end
end

class DispatcherCombinedTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_F_and_L_both_dispatched
    @disp.handle({ "F" => "1", "L" => "1", "R" => "0", "G" => "255", "B" => "0", "S" => "B", "M" => "s" })
    methods = @display.calls.map(&:first)
    assert_includes methods, :draw_ellipse
    assert_equal [:both, 0, 255, 0, :solid], @led.last_animate_side_args
  end

  def test_combined_success_writes_single_ack
    @disp.handle({ "F" => "1", "L" => "1", "R" => "0", "G" => "255", "B" => "0", "S" => "B", "M" => "s" })
    assert_equal ["."], @stdout.writes
  end

  def test_combined_partial_failure_writes_error
    @disp.handle({ "F" => "9", "L" => "1", "S" => "B", "M" => "o" })
    assert_equal ["?"], @stdout.writes
  end

  def test_unknown_keys_only_writes_error
    @disp.handle({ "Z" => "1" })
    assert_equal ["?"], @stdout.writes
  end

  def test_display_exception_writes_error
    @display.raise_on_fill = StandardError.new("boom")
    @disp.handle({ "F" => "0" })
    assert_equal ["?"], @stdout.writes
  end
end

class DispatcherSideKeyTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_S_both_passes_side_to_animate_side
    @disp.handle({ "L" => "1", "R" => "100", "G" => "0", "B" => "0", "S" => "B", "M" => "s" })
    assert_equal [:both, 100, 0, 0, :solid], @led.last_animate_side_args
    assert_equal ["."], @stdout.writes
  end

  def test_S_left
    @disp.handle({ "L" => "1", "R" => "100", "G" => "0", "B" => "0", "S" => "L", "M" => "s" })
    assert_equal [:left, 100, 0, 0, :solid], @led.last_animate_side_args
  end

  def test_S_right
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "200", "S" => "R", "M" => "b" })
    assert_equal [:right, 0, 0, 200, :blink], @led.last_animate_side_args
  end

  def test_missing_S_writes_error
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "0", "M" => "s" })
    assert_equal ["?"], @stdout.writes
    assert_nil @led.last_animate_side_args
  end

  def test_unknown_S_value_writes_error
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "0", "S" => "X", "M" => "s" })
    assert_equal ["?"], @stdout.writes
    assert_nil @led.last_animate_side_args
  end
end
