class LinkLoopTest < Picotest::Test
  class FakePort
    attr_reader :pops, :event_popped_count, :releases

    def initialize
      @events = []
      @pops = []
      @event_popped_count = 0
      @releases = 0
    end

    def queue_event(ev)
      @events << ev
    end

    def pop_event(timeout_ms:)
      @pops << timeout_ms
      @events.shift
    end

    def event_popped
      @event_popped_count += 1
    end

    def disconnect_central
      @releases += 1
    end
  end

  class NullDrb
    attr_accessor :active
    attr_reader :disconnects

    def initialize
      @active = false
      @disconnects = 0
    end

    def service(_port)
      was = @active
      @active = false
      was
    end

    def disconnected
      @disconnects += 1
    end
  end

  class NullRemote
    def perform_audio_play; end
  end

  class AudioPlayRemote
    def initialize(advance:)
      @advance = advance
      @fired = false
    end

    def perform_audio_play
      return false if @fired
      @fired = true
      @advance.call
      true
    end
  end

  class FakeTicker
    attr_reader :ticks

    def initialize
      @ticks = []
    end

    def tick(now_ms)
      @ticks << now_ms
    end
  end

  def setup
    @port    = FakePort.new
    @ticker  = FakeTicker.new
    @packets = []
    @now     = 5_000_000
    @drb     = NullDrb.new
    @link    = link_with(release_after: nil)
  end

  def link_with(release_after:, drb: @drb, remote: NullRemote.new)
    StackChan::Robot::LinkLoop.new(
      port: @port, ticker: @ticker,
      on_packet: ->(pkt) { @packets << pkt },
      clock: -> { @now },
      drb: drb,
      remote: remote,
      release_after: release_after,
    )
  end

  def drb_tick(link)
    @drb.active = true
    link.tick
  end

  def test_tick_pops_with_tick_ms_and_calls_event_popped_without_an_event
    @link.tick
    assert_equal [StackChan::Robot::LinkLoop::TICK_MS], @port.pops
    assert_equal 1, @port.event_popped_count
  end

  def test_tick_dispatches_string_events_only
    @port.queue_event("\x60\x00\x02")
    @link.tick
    @port.queue_event(:heartbeat)
    @link.tick
    assert_equal ["\x60\x00\x02"], @packets
  end

  def test_ticker_runs_every_tick_with_the_clock_in_ms
    @link.tick
    @now += 20_000
    @link.tick
    assert_equal [5000, 5020], @ticker.ticks
  end

  def test_tick_ms_is_20
    assert_equal 20, StackChan::Robot::LinkLoop::TICK_MS
  end

  def test_the_release_fires_once_release_after_ms_after_the_last_drb_traffic
    link = link_with(release_after: 1000)
    drb_tick(link)
    @now += 999_999
    link.tick
    assert_equal 0, @port.releases
    @now += 1
    link.tick
    assert_equal 1, @port.releases
    @now += 5_000_000
    link.tick
    link.tick
    assert_equal 1, @port.releases
  end

  def test_drb_traffic_restarts_the_release_timer
    link = link_with(release_after: 1000)
    drb_tick(link)
    @now += 800_000
    drb_tick(link)
    @now += 800_000
    link.tick
    assert_equal 0, @port.releases
    @now += 200_000
    link.tick
    assert_equal 1, @port.releases
  end

  def test_no_release_while_no_central_is_connected
    link = link_with(release_after: 1000)
    link.tick
    @now += 10_000_000
    link.tick
    assert_equal 0, @port.releases
    drb_tick(link)
    @now += 1_000_000
    link.tick
    link.disconnected
    @now += 10_000_000
    link.tick
    assert_equal 1, @port.releases
  end

  def test_the_next_central_is_released_again
    link = link_with(release_after: 1000)
    drb_tick(link)
    @now += 1_000_000
    link.tick
    link.disconnected
    drb_tick(link)
    @now += 1_000_000
    link.tick
    assert_equal 2, @port.releases
  end

  def test_a_dropped_central_is_not_released_after_the_disconnect
    link = link_with(release_after: 1000)
    drb_tick(link)
    link.disconnected
    @now += 1_000_000
    link.tick
    assert_equal 0, @port.releases
  end

  def test_without_release_after_the_link_is_never_released
    drb_tick(@link)
    @now += 3_600_000_000
    @link.tick
    assert_equal 0, @port.releases
  end

  def test_disconnected_resets_the_drb_channel
    @link.disconnected
    assert_equal 1, @drb.disconnects
  end

  def test_a_blocking_audio_play_refreshes_activity_so_the_next_tick_does_not_release
    remote = AudioPlayRemote.new(advance: -> { @now += 20_000_000 })
    link = link_with(release_after: 1000, remote: remote)
    drb_tick(link)
    @now += 999_999
    link.tick
    assert_equal 0, @port.releases
  end
end
