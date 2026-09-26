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
    assert_equal [:draw_rect, :draw_rect, :draw_ellipse, :draw_ellipse,
                  :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_a_face_command_repaints_only_the_eye_and_mouth_bands_never_the_whole_face_region
    @disp.handle({ "F" => "5" })
    rects = @display.calls.select { |c| c.first == :draw_rect }.map(&:last)
    assert_equal 2, rects.length
    full = rects.select { |r| r[2] == 320 && r[3] == StackchanApp::Face::FACE_REGION_HEIGHT }
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

  class RaisingDisplay
    def draw_rect(x, y, w, h, color, fill: false)
      raise IOError, "spi"
    end
  end

  def test_a_dispatch_exception_answers_question_mark
    disp = StackchanApp::Dispatcher.new(display: RaisingDisplay.new, led: @led, stdout: @stdout)
    disp.handle({ "F" => "0" })
    assert_equal ["?\n"], @stdout.writes
  end

  class FlashLed
    attr_reader :flashes
    def initialize; @flashes = []; end
    def flash_side(side, r, g, b); @flashes << [side, r, g, b]; end
  end

  def touch(zone)
    led = FlashLed.new
    disp = StackchanApp::Dispatcher.new(display: @display, led: led, stdout: @stdout)
    disp.react_to_touch(zone)
    [disp.current_face_class, led.flashes]
  end

  def test_touch_zone_0_draws_surprised_and_flashes_both_green
    assert_equal [StackchanApp::Face::Surprised, [[:both, 0, 60, 0]]], touch(0)
  end

  def test_touch_zone_1_draws_angry_and_flashes_right_red
    assert_equal [StackchanApp::Face::Angry, [[:right, 60, 0, 0]]], touch(1)
  end

  def test_touch_zone_2_draws_sad_and_flashes_left_blue
    assert_equal [StackchanApp::Face::Sad, [[:left, 0, 0, 60]]], touch(2)
  end

  def test_touch_redraws_the_face_on_the_display
    touch(1)
    assert_equal 4, @display.calls.select { |c| c.first == :draw_line }.size
  end
end
