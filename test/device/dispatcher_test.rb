class DispatcherFaceTest < Picotest::Test
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
    assert_equal [:batch, :draw_ellipse, :draw_ellipse,
                  :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  # A face command repaints only the eye/mouth union band. Falling back to the
  # full 320x200 fill would still look right on the panel — only the clock
  # would show it, at about a second per face — so pin it here.
  def test_a_face_command_never_fills_the_whole_face_region
    @disp.handle({ "F" => "5" })
    batches = @display.calls.select { |c| c.first == :batch }.map(&:last)
    assert_equal 1, batches.length
    full = batches.select { |r| r[2] == 320 && r[3] == StackchanApp::Face::FACE_REGION_HEIGHT }
    assert_equal 0, full.length
  end

  def test_F_known_writes_ack_dot
    @disp.handle({ "F" => "0" })
    assert(@stdout.writes.include?(".\n"))
  end

  def test_F_unknown_writes_question_mark
    @disp.handle({ "F" => "99" })
    assert(@stdout.writes.include?("?\n"))
  end
end
