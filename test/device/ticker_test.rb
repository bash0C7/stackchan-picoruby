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

  class FakeFaceClass
    LOG = []

    def redraw_eyes_closed(_display)
      LOG << :closed
    end

    def redraw_eyes_open(_display)
      LOG << :open
    end
  end

  class FakeDispatcher
    attr_reader :touches

    def initialize
      @touches = []
    end

    def react_to_touch(zone)
      @touches << zone
    end

    def current_face_class
      FakeFaceClass
    end
  end

  def setup
    @display    = FakeDisplay.new
    @led        = FakeLed.new
    @touch      = FakeTouch.new
    @dispatcher = FakeDispatcher.new
    @notified   = []
    FakeFaceClass::LOG.clear
    @ticker = StackchanApp::Ticker.new(
      display: @display, led: @led, touch: @touch, dispatcher: @dispatcher,
      notify: ->(frame) { @notified << frame }
    )
  end

  def led_ticks
    @led.calls.select { |c| c.first == :tick }.map { |c| c.last.first }
  end

  def test_touch_polls_on_the_first_tick_then_every_50ms
    @ticker.tick(1000)
    @ticker.tick(1049)
    assert_equal 1, @touch.polls
    @ticker.tick(1050)
    assert_equal 2, @touch.polls
  end

  def test_touch_onset_reacts_locally_and_notifies
    @touch.next_zone = 2
    @ticker.tick(1000)
    assert_equal [2], @dispatcher.touches
    assert_equal ["<touch:2>\n"], @notified
  end

  def test_no_touch_sensor_is_skipped
    t = StackchanApp::Ticker.new(display: @display, led: @led, touch: nil, dispatcher: @dispatcher,
                                 notify: ->(frame) { @notified << frame })
    t.tick(1000)
    assert_equal [], @notified
  end

  def test_touch_poll_error_is_swallowed
    @touch.raise_next = true
    @ticker.tick(1000)
    @touch.next_zone = 0
    @ticker.tick(1050)
    assert_equal [0], @dispatcher.touches
  end

  def test_led_ticks_every_50ms_with_the_current_time
    @ticker.tick(1000)
    @ticker.tick(1020)
    @ticker.tick(1050)
    assert_equal [1000, 1050], led_ticks
  end

  def test_blink_closes_after_5s_and_opens_150ms_later_without_delay_ms
    before = Machine.uptime_us
    @ticker.tick(1000)
    @ticker.tick(5999)
    assert_equal [], FakeFaceClass::LOG
    @ticker.tick(6000)
    assert_equal [:closed], FakeFaceClass::LOG
    @ticker.tick(6100)
    assert_equal [:closed], FakeFaceClass::LOG
    @ticker.tick(6150)
    assert_equal [:closed, :open], FakeFaceClass::LOG
    assert_equal before, Machine.uptime_us
  end

  def test_blink_repeats_5s_after_the_previous_close
    @ticker.tick(0)
    @ticker.tick(5000)
    @ticker.tick(5150)
    @ticker.tick(9999)
    assert_equal [:closed, :open], FakeFaceClass::LOG
    @ticker.tick(10000)
    assert_equal [:closed, :open, :closed], FakeFaceClass::LOG
  end
end
