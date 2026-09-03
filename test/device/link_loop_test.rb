class LinkLoopTest < Picotest::Test
  RX   = 0x11
  TX   = 0x14
  CCCD = 0x15

  class FakePort
    attr_reader :pops, :event_popped_count, :notifies

    def initialize
      @events = []
      @writes = {}
      @pops = []
      @event_popped_count = 0
      @notifies = []
      @on_event_popped = nil
    end

    def queue_event(ev)
      @events << ev
    end

    def queue_write(handle, value)
      (@writes[handle] ||= []) << value
    end

    # Model data that only becomes visible to Ruby when the port drains.
    def on_event_popped(&blk)
      @on_event_popped = blk
    end

    def pop_event(timeout_ms:)
      @pops << timeout_ms
      @events.shift
    end

    def event_popped
      @event_popped_count += 1
      @on_event_popped.call if @on_event_popped
    end

    def take_write(handle)
      list = @writes[handle]
      list && list.shift
    end

    def send_notification(handle, frame)
      @notifies << [handle, frame]
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
    @rx      = []
    @logs    = []
    @now     = 5_000_000   # microseconds
    # on_rx models the dispatcher: record, take 15 ms, answer with an ACK.
    @link = StackchanApp::LinkLoop.new(
      port: @port, rx_handle: RX, tx_handle: TX, cccd_handle: CCCD,
      ticker: @ticker,
      on_packet: ->(pkt) { @packets << pkt },
      on_rx: ->(data) { @rx << data; @now += 15_000; @link.write(".\n") },
      clock: -> { @now },
      log: ->(line) { @logs << line },
    )
  end

  def subscribe
    @port.queue_write(CCCD, "\x01\x00")
    @link.tick
  end

  def stamp_lines
    @logs.select { |l| l.start_with?("[t]") }
  end

  def test_tick_pops_with_tick_ms_and_calls_event_popped_without_an_event
    @link.tick
    assert_equal [StackchanApp::LinkLoop::TICK_MS], @port.pops
    assert_equal 1, @port.event_popped_count
  end

  def test_tick_dispatches_string_events_only
    @port.queue_event("\x60\x00\x02")
    @link.tick
    @port.queue_event(:heartbeat)
    @link.tick
    assert_equal ["\x60\x00\x02"], @packets
  end

  def test_tick_drains_every_rx_write_in_one_tick
    @port.queue_write(RX, "<F:2>\n")
    @port.queue_write(RX, "<F:3>\n")
    @link.tick
    assert_equal ["<F:2>\n", "<F:3>\n"], @rx
  end

  def test_writes_that_arrive_with_the_drain_are_handled_in_the_same_tick
    @port.on_event_popped { @port.queue_write(RX, "<F:1>\n") }
    @link.tick
    assert_equal ["<F:1>\n"], @rx
  end

  def test_write_before_subscribe_is_dropped
    @link.write(".\n")
    assert_equal [], @port.notifies
    assert_false @link.notify_enabled?
  end

  def test_subscribe_in_the_same_tick_as_the_first_command_still_acks
    @port.queue_write(CCCD, "\x01\x00")
    @port.queue_write(RX, "<F:2>\n")
    @link.tick
    assert_equal [[TX, ".\n"]], @port.notifies
  end

  def test_write_after_subscribe_notifies_immediately_and_in_order
    subscribe
    @link.write(".\n")
    @link.write("<YL_actual:1,PU_actual:2>\n")
    assert_equal [[TX, ".\n"], [TX, "<YL_actual:1,PU_actual:2>\n"]], @port.notifies
    assert @link.notify_enabled?
  end

  def test_cccd_disable_and_disconnected_close_the_gate
    subscribe
    @port.queue_write(CCCD, "\x00\x00")
    @link.tick
    @link.write(".\n")
    assert_equal [], @port.notifies
    subscribe
    @link.disconnected
    @link.write(".\n")
    assert_equal [], @port.notifies
  end

  def test_ticker_runs_every_tick_with_the_clock_in_ms
    @link.tick
    @now += 20_000
    @link.tick
    assert_equal [5000, 5020], @ticker.ticks
  end

  def test_pump_is_non_blocking_and_dispatches
    @port.queue_event("\x05\x00")
    assert_equal "\x05\x00", @link.pump
    assert_equal [0], @port.pops
    assert_equal 1, @port.event_popped_count
    assert_equal ["\x05\x00"], @packets
    assert_nil @link.pump
  end

  def test_one_stamp_line_per_command_with_rx_to_ack_delta
    subscribe
    @port.queue_write(RX, "<F:2>\n")
    @link.tick
    assert_equal ["[t] rx=5000000 ack=5015000 d=15000"], stamp_lines
    @link.write("<YL_actual:1,PU_actual:2>\n")   # second frame of the same command
    assert_equal 1, stamp_lines.size
  end

  def test_no_stamp_without_a_preceding_rx
    subscribe
    @link.write("<touch:1>\n")
    assert_equal [], stamp_lines
  end

  def test_tick_ms_is_20
    assert_equal 20, StackchanApp::LinkLoop::TICK_MS
  end

  def test_dropped_write_does_not_leave_a_stale_rx_stamp
    @port.queue_write(RX, "<F:2>\n")   # gate closed: on_rx's ACK write is dropped
    @link.tick
    subscribe
    @link.write("<touch:1>\n")
    assert_equal [], stamp_lines
  end

  def test_disconnected_clears_the_rx_stamp
    silent = StackchanApp::LinkLoop.new(
      port: @port, rx_handle: RX, tx_handle: TX, cccd_handle: CCCD,
      ticker: @ticker,
      on_packet: ->(pkt) { @packets << pkt },
      on_rx: ->(data) { @rx << data },      # records only, never answers
      clock: -> { @now },
      log: ->(line) { @logs << line },
    )
    @port.queue_write(CCCD, "\x01\x00")
    @port.queue_write(RX, "<F:2>\n")
    silent.tick                          # rx stamp latched, nothing notified
    silent.disconnected
    @port.queue_write(CCCD, "\x01\x00")
    silent.tick
    silent.write("<touch:1>\n")
    assert_equal [], stamp_lines
  end
end
