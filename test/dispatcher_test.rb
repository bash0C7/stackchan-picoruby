$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class DispatcherFaceTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = MiniSink.new
    @disp    = StackchanApp::Dispatcher.new(display: @display, led: @led, stdout: @stdout)
  end

  class MiniSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def test_F_0_draws_neutral
    @disp.handle({ "F" => "0" })
    assert @display.calls.any? { |c| c.first == :draw_ellipse }
  end

  def test_F_4_draws_sad
    @disp.handle({ "F" => "4" })
    line = @display.calls.find { |c| c.first == :draw_line }.last
    assert_equal 148, line[1]
  end

  def test_F_5_draws_angry_with_brows
    @disp.handle({ "F" => "5" })
    methods = @display.calls.map(&:first)
    assert_equal [:draw_rect, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_F_known_writes_ack_dot
    @disp.handle({ "F" => "0" })
    assert_includes @stdout.writes, ".\n"
  end

  def test_F_unknown_writes_question_mark
    @disp.handle({ "F" => "99" })
    assert_includes @stdout.writes, "?\n"
  end
end
