class TickerTest < Picotest::Test
  class FakeTouch
    attr_accessor :next_zone, :raise_next
    attr_reader :polls

    def initialize
      @polls = 0
      @next_zone = nil
      @raise_next = false
    end

    def poll
      @polls += 1
      if @raise_next
        @raise_next = false
        raise "i2c fail"
      end
      z = @next_zone
      @next_zone = nil
      z
    end
  end

  class FakeFace
    LOG = []

    def redraw_eyes_closed(_display)
      LOG << :closed
    end

    def redraw_eyes_open(_display)
      LOG << :open
    end
  end

  def setup
    @display    = FakeDisplay.new
    @led        = FakeLed.new
    @touch      = FakeTouch.new
    @dispatcher = RobotTables.dispatcher(display: @display, led: @led, stdout: nil)
    @notified   = []
    FakeFace::LOG.clear
    @ticker = ticker
  end

  def ticker(touch: @touch, dispatcher: @dispatcher, touch_handlers: RobotTables.touch_handlers, periodic: [])
    StackChan::Robot::Ticker.new(
      display: @display, led: @led, touch: touch, dispatcher: dispatcher,
      notify: ->(frame) { @notified << frame },
      touch_handlers: touch_handlers, periodic: periodic
    )
  end

  def led_ticks
    @led.calls.select { |c| c.first == :tick }.map { |c| c.last.first }
  end

  def flashes
    @led.calls.select { |c| c.first == :flash_side }.map(&:last)
  end

  def blinking_dispatcher
    face = FakeFace.new
    StackChan::Robot::Dispatcher.new(
      display: @display, led: @led, stdout: nil,
      faces: { neutral: face, closed: face }, face_index: {}
    )
  end

  def test_touch_polls_on_the_first_tick_then_every_50ms
    @ticker.tick(1000)
    @ticker.tick(1049)
    assert_equal 1, @touch.polls
    @ticker.tick(1050)
    assert_equal 2, @touch.polls
  end

  def test_touch_zone_0_draws_surprised_and_flashes_both_green
    @touch.next_zone = 0
    @ticker.tick(1000)
    assert_equal :open, @dispatcher.current_face.mouth
    assert_equal [[:both, 0, 60, 0, 300]], flashes
    assert_equal ["<touch:0>\n"], @notified
  end

  def test_touch_zone_1_draws_angry_and_flashes_right_red
    @touch.next_zone = 1
    @ticker.tick(1000)
    assert_equal :angry, @dispatcher.current_face.brows
    assert_equal [[:right, 60, 0, 0, 300]], flashes
  end

  def test_touch_zone_2_draws_sad_and_flashes_left_blue
    @touch.next_zone = 2
    @ticker.tick(1000)
    assert_equal(-8, @dispatcher.current_face.mouth)
    assert_equal [[:left, 0, 0, 60, 300]], flashes
    assert_equal ["<touch:2>\n"], @notified
  end

  def test_touch_redraws_the_face_on_the_display
    @touch.next_zone = 1
    @ticker.tick(1000)
    assert_equal 4, @display.calls.select { |c| c.first == :draw_line }.size
  end

  def test_a_zone_without_a_handler_still_notifies_and_draws_nothing
    t = ticker(touch_handlers: {})
    @touch.next_zone = 1
    t.tick(1000)
    assert_equal ["<touch:1>\n"], @notified
    assert_equal [], @display.calls
    assert_equal [], flashes
  end

  def test_a_touch_handler_receives_the_handle
    got = []
    t = ticker(touch_handlers: { 1 => ->(r) { got << r } })
    @touch.next_zone = 1
    t.tick(1000)
    assert_equal [@dispatcher.robot_handle], got
  end

  def test_no_touch_sensor_is_skipped
    t = ticker(touch: nil)
    t.tick(1000)
    assert_equal [], @notified
  end

  def test_touch_poll_error_is_swallowed
    @touch.raise_next = true
    @ticker.tick(1000)
    @touch.next_zone = 0
    @ticker.tick(1050)
    assert_equal ["<touch:0>\n"], @notified
  end

  def test_a_raising_touch_handler_is_logged_and_skips_the_notify
    t = ticker(touch_handlers: { 0 => ->(_r) { raise IOError, "led" } })
    @touch.next_zone = 0
    t.tick(1000)
    assert_equal [], @notified
    @touch.next_zone = 0
    t.tick(1050)
    assert_equal [], @notified
  end

  def test_led_ticks_every_50ms_with_the_current_time
    @ticker.tick(1000)
    @ticker.tick(1020)
    @ticker.tick(1050)
    assert_equal [1000, 1050], led_ticks
  end

  def test_a_periodic_handler_fires_one_period_after_the_first_tick_then_every_period
    fired = []
    t = ticker(periodic: [[300, ->(r) { fired << r }]])
    t.tick(1000)
    t.tick(1299)
    assert_equal [], fired
    t.tick(1300)
    assert_equal 1, fired.size
    t.tick(1599)
    assert_equal 1, fired.size
    t.tick(1600)
    assert_equal [@dispatcher.robot_handle, @dispatcher.robot_handle], fired
  end

  def test_periodic_handlers_keep_their_own_periods
    fired = []
    t = ticker(periodic: [[100, ->(_r) { fired << :a }], [250, ->(_r) { fired << :b }]])
    t.tick(0)
    t.tick(100)
    t.tick(200)
    t.tick(250)
    t.tick(300)
    assert_equal [:a, :a, :b, :a], fired
  end

  def test_a_periodic_handler_reaches_the_led
    t = ticker(periodic: [[500, ->(r) { r.led(:both, [1, 2, 3], mode: :breathing) }]])
    t.tick(0)
    t.tick(500)
    assert_equal [[:animate_side, [:both, 1, 2, 3, :breathing]]], @led.calls.select { |c| c.first == :animate_side }
  end

  def test_blink_closes_after_5s_and_opens_150ms_later_without_delay_ms
    t = ticker(dispatcher: blinking_dispatcher, periodic: [[5000, ->(r) { r.blink(150) }]])
    before = Machine.uptime_us
    t.tick(1000)
    t.tick(5999)
    assert_equal [], FakeFace::LOG
    t.tick(6000)
    assert_equal [:closed], FakeFace::LOG
    t.tick(6100)
    assert_equal [:closed], FakeFace::LOG
    t.tick(6150)
    assert_equal [:closed, :open], FakeFace::LOG
    assert_equal before, Machine.uptime_us
  end

  def test_blink_repeats_5s_after_the_previous_close
    t = ticker(dispatcher: blinking_dispatcher, periodic: [[5000, ->(r) { r.blink(150) }]])
    t.tick(0)
    t.tick(5000)
    t.tick(5150)
    t.tick(9999)
    assert_equal [:closed, :open], FakeFace::LOG
    t.tick(10000)
    assert_equal [:closed, :open, :closed], FakeFace::LOG
  end

  def test_without_a_periodic_blink_the_eyes_never_close
    t = ticker(dispatcher: blinking_dispatcher)
    t.tick(0)
    t.tick(5000)
    t.tick(10000)
    assert_equal [], FakeFace::LOG
  end

  def test_blink_reopens_on_the_real_face_with_its_eyes
    t = ticker(periodic: [[5000, ->(r) { r.blink(150) }]])
    t.tick(0)
    @display.calls.clear
    t.tick(5000)
    assert_equal [:draw_rect, :draw_rect, :draw_line, :draw_line], @display.calls.map(&:first)
    @display.calls.clear
    t.tick(5150)
    assert_equal [:draw_rect, :draw_rect, :draw_ellipse, :draw_ellipse], @display.calls.map(&:first)
  end
end
