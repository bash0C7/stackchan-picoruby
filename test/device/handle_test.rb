class HandleTest < Picotest::Test
  class FakeServo
    attr_reader :writes
    def initialize; @writes = []; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; 0; end
  end

  class MiniSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = MiniSink.new
    @yaw     = FakeServo.new
    @pitch   = FakeServo.new
    @disp    = RobotTables.dispatcher(
      display: @display, led: @led, stdout: @stdout,
      head: StackChan::Robot::Head.new(@yaw, @pitch)
    )
    @r = @disp.robot_handle
  end

  def test_face_redraws_the_named_face_and_makes_it_current
    assert_equal true, @r.face(:angry)
    assert_equal :angry, @disp.current_face.brows
    assert_equal 4, @display.calls.select { |c| c.first == :draw_line }.size
  end

  def test_an_unknown_face_is_false_and_draws_nothing
    assert_equal false, @r.face(:wink)
    assert_equal [], @display.calls
    assert_equal 0, @disp.current_face.mouth
  end

  def test_led_without_flash_animates_the_side_in_the_mode
    @r.led(:right, [1, 2, 3], mode: :blink)
    assert_equal [[:animate_side, [:right, 1, 2, 3, :blink]]], @led.calls
  end

  def test_led_mode_defaults_to_solid
    @r.led(:both, [4, 5, 6])
    assert_equal [[:animate_side, [:both, 4, 5, 6, :solid]]], @led.calls
  end

  def test_led_with_flash_flashes_the_side_for_that_many_ms
    @r.led(:left, [0, 0, 60], flash: 120)
    assert_equal [[:flash_side, [:left, 0, 0, 60, 120]]], @led.calls
  end

  def test_head_yaw_left_and_pitch_up_write_the_same_raw_positions_as_the_frame
    assert_equal true, @r.head(yaw_left: 50, pitch_up: 50, time: 2000)
    assert_equal [[332, 2000, 0]], @yaw.writes
    assert_equal [[781, 2000, 0]], @pitch.writes
  end

  def test_head_yaw_right_writes_above_the_forward_zero
    assert_equal true, @r.head(yaw_right: 50, time: 1000)
    assert_equal [[632, 1000, 0]], @yaw.writes
    assert_equal [], @pitch.writes
  end

  def test_head_time_defaults_to_zero
    @r.head(pitch_up: 0)
    assert_equal [[633, 0, 0]], @pitch.writes
  end

  def test_head_out_of_range_is_false_and_moves_nothing
    assert_equal false, @r.head(yaw_left: 101)
    assert_equal false, @r.head(pitch_up: -1)
    assert_equal [], @yaw.writes
    assert_equal [], @pitch.writes
  end

  def test_head_without_any_axis_is_false
    assert_equal false, @r.head(time: 100)
  end

  def test_head_writes_nothing_to_the_link
    @r.head(yaw_left: 10)
    assert_equal [], @stdout.writes
  end

  def test_text_draws_the_subtitle_like_the_text_frame
    via_handle = FakeDisplay.new
    via_frame  = FakeDisplay.new
    RobotTables.dispatcher(display: via_handle, led: @led, stdout: @stdout).robot_handle.text("やあ")
    RobotTables.dispatcher(display: via_frame, led: @led, stdout: MiniSink.new).handle({ "text" => "やあ" })
    assert_equal via_frame.calls, via_handle.calls
    assert_equal "やあ", via_handle.calls.find { |c| c.first == :draw_text }.last[2]
  end

  def test_say_ready_is_whether_a_speaker_is_present
    assert_false @r.say_ready?
    with = RobotTables.dispatcher(display: @display, led: @led, stdout: @stdout, speaker: Object.new)
    assert_true with.robot_handle.say_ready?
  end

  def test_blink_closes_the_current_face_eyes_now
    StackChan::Robot::Ticker.new(display: @display, led: @led, touch: nil, dispatcher: @disp,
                                 notify: ->(_f) {})
    @r.face(:angry)
    @display.calls.clear
    @r.blink(150)
    assert_equal [:draw_rect, :draw_rect, :draw_line, :draw_line], @display.calls.map(&:first)
  end

  def test_blink_reopens_after_closed_ms_on_the_ticker
    ticker = StackChan::Robot::Ticker.new(display: @display, led: @led, touch: nil, dispatcher: @disp,
                                          notify: ->(_f) {})
    ticker.tick(1000)
    @r.blink(200)
    @display.calls.clear
    ticker.tick(1199)
    assert_equal [], @display.calls
    ticker.tick(1200)
    assert_equal [:draw_rect, :draw_rect, :draw_ellipse, :draw_ellipse], @display.calls.map(&:first)
    @display.calls.clear
    ticker.tick(1400)
    assert_equal [], @display.calls
  end
end
