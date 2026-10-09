class LinkTest < Picotest::Test
  RX    = FakeRobotRadio::RX
  CCCD  = FakeRobotRadio::CCCD
  DCCCD = FakeRobotRadio::DCCCD
  TICK_MS = 250

  class StampedRobotRadio < FakeRobotRadio
    attr_reader :stamps, :events

    def initialize
      super
      @stamps = []
      @events = []
    end

    def before_drx_write(value)
      @events << [:frame, "touches"]  if value.include?("touches")
      @events << [:frame, "command"] if value.include?("command")
      @stamps << [FakeClock.now, "touches"] if value.include?("touches")
      :continue
    end

    def write_characteristic_descriptor_using_descriptor_handle(conn_handle, handle, value)
      super
      @events << [:descriptor, handle]
    end
  end

  class DropOnTouchesRadio < StampedRobotRadio
    def before_drx_write(value)
      if value.include?("touches")
        @stamps << [FakeClock.now, "touches"]
        drop_link(event: true)
        return :drop
      end
      super
    end
  end

  TX = FakeRobotRadio::TX

  def build(hold: 10_000, radio: nil)
    FakeClock.reset(0)
    @logs = []
    @radio = radio || StampedRobotRadio.new
    @central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(line) {})
    @link = StackChan::Controller::Link.new(central: @central, clock: -> { FakeClock.now }, hold: hold, log: ->(line) { @logs << line })
  end

  def setup
    build
  end

  def tick_until(t)
    while FakeClock.now < t
      sleep_ms TICK_MS
      @link.tick
    end
  end

  def act_frame(frame)
    @link.act { @central.raw_send(frame) }
    FakeClock.now
  end

  def touches_offsets(t0)
    offsets = []
    @radio.stamps.each { |t, frame| offsets << t - t0 if frame == "touches" }
    offsets
  end

  def sleep_total
    total = 0
    FakeClock.sleeps.each { |ms| total += ms }
    total
  end

  def test_the_keepalive_fires_every_second_in_the_hold_then_quiet
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 9_750)
    assert_equal (1..9).map { |i| i * 1000 }, touches_offsets(t0)
    assert_equal :held, @link.state
    tick_until(t0 + 10_000)
    assert_equal :quiet, @link.state
    tick_until(t0 + 60_000)
    assert_equal (1..9).map { |i| i * 1000 }, touches_offsets(t0)
    assert_equal :quiet, @link.state
  end

  def test_an_action_in_quiet_restarts_the_keepalive
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 12_000)
    act_frame("<F:3>\n")
    tick_until(t0 + 19_000)
    assert_equal 16, touches_offsets(t0).size
    assert_equal :held, @link.state
    assert_equal 1, @radio.connect_and_discover_calls
  end

  def test_a_keepalive_timeout_on_a_link_not_known_lost_goes_quiet_and_never_reconnects
    t0 = act_frame("<F:2>\n")
    @radio.drop_link(event: false)
    tick_until(t0 + 60_000)
    assert_equal :quiet, @link.state
    assert_equal 0, @link.status[:releases]
    assert_equal 1, @radio.connect_and_discover_calls
  end

  def test_a_keepalive_that_sees_the_link_drop_releases_it
    build(radio: DropOnTouchesRadio.new)
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 60_000)
    assert_equal :released, @link.state
    assert_equal [1_000], touches_offsets(t0)
    assert_equal 1, @radio.connect_and_discover_calls
  end

  def test_an_action_drains_a_release_no_tick_has_seen
    @radio.release_after(15_000)
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 21_750)
    assert_equal :quiet, @link.state
    sleep_ms 3_000
    FakeClock.sleeps.clear
    @radio.events.clear
    act_frame("<F:3>\n")
    assert_equal 2, @radio.connect_and_discover_calls
    assert_equal StackChan::Controller::Central::SUBSCRIBE_SETTLE_MS, sleep_total
    assert_equal [[:descriptor, CCCD], [:descriptor, DCCCD], [:frame, "command"]], @radio.events
    assert_equal :held, @link.state
  end

  def test_the_robot_release_is_seen_by_packet_one_tick_after_its_quiet_time
    @radio.release_after(15_000)
    t0 = act_frame("<F:2>\n")
    FakeClock.sleeps.clear
    tick_until(t0 + 21_750)
    assert_equal :quiet, @link.state
    tick_until(t0 + 24_250)
    assert_equal :released, @link.state
    assert_equal [TICK_MS], FakeClock.sleeps.uniq
    assert_equal 1, @link.status[:releases]
  end

  def test_an_action_after_a_packet_release_reconnects_before_its_frame
    @radio.release_after(15_000)
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 24_250)
    FakeClock.sleeps.clear
    @radio.events.clear
    act_frame("<F:3>\n")
    assert_equal 2, @radio.connect_and_discover_calls
    assert_equal StackChan::Controller::Central::SUBSCRIBE_SETTLE_MS, sleep_total
    assert_equal [[:descriptor, CCCD], [:descriptor, DCCCD], [:frame, "command"]], @radio.events
    assert_equal :held, @link.state
  end

  def test_a_silent_drop_in_quiet_times_out_once_without_a_rescan
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 10_000)
    @radio.drop_link(event: false)
    FakeClock.sleeps.clear
    runs = 0
    assert_raise(StackChan::Controller::TimeoutError) do
      @link.act do
        runs += 1
        @central.raw_send("<F:3>\n")
      end
    end
    assert_equal 1, runs
    assert_equal StackChan::Controller::Central::ACK_TIMEOUT_MS, sleep_total
    assert_equal 1, @radio.connect_and_discover_calls
    assert_equal :quiet, @link.state
  end

  def test_an_ack_timeout_on_a_held_link_leaves_it_held
    act_frame("<F:2>\n")
    @radio.drop_link(event: false)
    assert_raise(StackChan::Controller::TimeoutError) { act_frame("<F:3>\n") }
    assert_equal :held, @link.state
    assert_equal 0, @link.status[:releases]
  end

  def test_an_action_whose_link_is_lost_during_its_block_stays_released
    act_frame("<F:2>\n")
    @link.act { @link.lost! }
    assert_equal :released, @link.state
  end

  def test_an_action_whose_block_drains_a_drop_ends_released
    act_frame("<F:2>\n")
    @link.act do
      @radio.drop_link(event: true)
      @central.drain
    end
    assert_equal :released, @link.state
  end

  def test_the_generation_counts_connects
    assert_equal 0, @link.generation
    act_frame("<F:2>\n")
    @radio.drop_link(event: true)
    @link.tick
    act_frame("<F:3>\n")
    assert_equal 2, @link.generation
  end

  def test_a_tick_that_may_not_expire_the_hold_keeps_the_keepalive
    t0 = act_frame("<F:2>\n")
    while FakeClock.now < t0 + 2_500
      sleep_ms TICK_MS
      @link.tick(expire: false)
    end
    assert_equal :held, @link.state
    assert_equal [1_000, 2_000], touches_offsets(t0)
  end

  def test_a_loss_calls_on_lost
    calls = 0
    @link.on_lost = -> { calls += 1 }
    act_frame("<F:2>\n")
    @radio.drop_link(event: true)
    @link.tick
    assert_equal 1, calls
  end

  def test_a_connection_error_in_the_block_is_not_retried
    act_frame("<F:2>\n")
    runs = 0
    assert_raise(StackChan::Controller::ConnectionError) do
      @link.act do
        runs += 1
        raise StackChan::Controller::ConnectionError, "gone"
      end
    end
    assert_equal 1, runs
    assert_equal :released, @link.state
    act_frame("<F:3>\n")
    assert_equal 2, @radio.connect_and_discover_calls
  end

  def test_a_robot_that_does_not_advertise_is_busy_until_the_next_action
    @radio.advertising = false
    runs = 0
    assert_raise(StackChan::Controller::Busy) { @link.act { runs += 1 } }
    assert_equal 0, runs
    assert_equal "busy", @link.status[:link]
    tick_until(60_000)
    assert_equal 1, @radio.connect_and_discover_calls
    @radio.advertising = true
    @link.act { runs += 1 }
    assert_equal 1, runs
    assert_equal 2, @radio.connect_and_discover_calls
    assert_equal :held, @link.state
  end

  def test_without_hold_the_keepalive_never_stops
    build(hold: nil)
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 5_000)
    assert_equal [1_000, 2_000, 3_000, 4_000, 5_000], touches_offsets(t0)
    assert_equal :held, @link.state
  end

  def test_a_touch_while_released_is_never_delivered
    @radio.release_after(15_000)
    t0 = act_frame("<F:2>\n")
    tick_until(t0 + 24_250)
    @radio.touch(1)
    tick_until(t0 + 30_000)
    act_frame("<F:3>\n")
    assert_equal [], @link.touches
  end

  def test_a_touch_queued_before_a_loss_is_cleared
    t0 = act_frame("<F:2>\n")
    @radio.touch(1)
    tick_until(t0 + 1_000)
    assert_equal [1], @link.touches
    @radio.drop_link(event: true)
    tick_until(t0 + 1_250)
    assert_equal :released, @link.state
    assert_equal [], @link.touches
  end

  def test_status_counts_connects_and_releases
    act_frame("<F:2>\n")
    @radio.drop_link(event: true)
    @link.tick
    act_frame("<F:3>\n")
    status = @link.status
    assert_equal "held", status[:link]
    assert_equal 2, status[:connects]
    assert_equal 1, status[:releases]
    assert_equal StackChan::Controller::Central::SUBSCRIBE_SETTLE_MS, status[:last_connect_ms]
    assert_equal 10_000, status[:hold_ms]
  end
end
