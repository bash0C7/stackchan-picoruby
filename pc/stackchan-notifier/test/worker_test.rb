require "helper"
require "stackchan_notifier/tuple_space4ractor"
require "stackchan_notifier/worker"

# Records each (kind, params, ctx) deliver call; lets a test script raise on demand.
class RecordingHandler
  attr_reader :calls
  def initialize(kind)
    @kind  = kind
    @calls = []
    @raise = nil
  end
  def raise_on_next(error_class, message = "boom")
    @raise = [error_class, message]
  end
  def deliver(client:, params:, ctx:)
    @calls << { kind: @kind, params: params }
    if (r = @raise)
      @raise = nil
      raise r[0], r[1]
    end
  end
end

def make_handlers_with(notify: RecordingHandler.new(:notify),
                      servo:  RecordingHandler.new(:servo),
                      raw:    RecordingHandler.new(:raw))
  { notify: notify, servo: servo, raw: raw }
end

class WorkerSingleNotifyTest < Test::Unit::TestCase
  def setup
    @ts = StackchanNotifier::TupleSpace4Ractor.new
    @client = FakeBleClient.new
    @notify_h = RecordingHandler.new(:notify)
    @worker = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      handlers:       make_handlers_with(notify: @notify_h),
      logger:         build_capturing_logger([]),
    )
    @worker.start
  end

  def teardown
    @worker.shutdown(timeout: 2.0)
  end

  def test_notify_tuple_dispatched_to_notify_handler
    @ts.write([:cmd, :notify, { face: :joy, left: [0,:solid], right: [0,:solid], duration: nil, silent: false }])
    wait_until(timeout: 1.0) { !@notify_h.calls.empty? }
    assert_equal 1, @notify_h.calls.size
    assert_equal :joy, @notify_h.calls[0][:params][:face]
  end
end

class WorkerDrainPerKindTest < Test::Unit::TestCase
  def setup
    @ts = StackchanNotifier::TupleSpace4Ractor.new
    @client = FakeBleClient.new
    @notify_h = RecordingHandler.new(:notify)
    @servo_h  = RecordingHandler.new(:servo)
    @raw_h    = RecordingHandler.new(:raw)
    @worker = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      handlers:       { notify: @notify_h, servo: @servo_h, raw: @raw_h },
      logger:         build_capturing_logger([]),
    )
  end

  def teardown
    @worker.shutdown(timeout: 2.0) if @worker.thread
  end

  def test_burst_collapses_to_latest_per_kind_in_first_seen_order
    # Pre-load tuples BEFORE start so the take + drain sees them in one shot.
    @ts.write([:cmd, :notify, { face: :smile, left: [0,:solid], right: [0,:solid], duration: nil, silent: false }])
    @ts.write([:cmd, :servo,  { yaw: 100, pitch: nil, time_ms: nil, velocity: nil }])
    @ts.write([:cmd, :notify, { face: :joy,   left: [0,:solid], right: [0,:solid], duration: nil, silent: false }])
    @ts.write([:cmd, :servo,  { yaw: 200, pitch: nil, time_ms: nil, velocity: nil }])

    @worker.start
    wait_until(timeout: 1.0) { @notify_h.calls.size >= 1 && @servo_h.calls.size >= 1 }

    # latest-wins per kind: notify=:joy (last), servo=yaw 200 (last)
    assert_equal 1, @notify_h.calls.size
    assert_equal :joy, @notify_h.calls[0][:params][:face]
    assert_equal 1, @servo_h.calls.size
    assert_equal 200, @servo_h.calls[0][:params][:yaw]
  end

  def test_unknown_kind_is_logged_warn_and_skipped
    log_events = []
    @worker = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      handlers:       { notify: @notify_h },          # no :servo handler
      logger:         build_severity_capturing_logger(log_events),
    )
    @ts.write([:cmd, :servo, { yaw: 0 }])
    @worker.start

    wait_until(timeout: 1.0) { log_events.any? { |sev, _| sev == "WARN" } }
    warn_msg = log_events.find { |sev, _| sev == "WARN" }[1]
    assert_match(/no handler for kind=servo/, warn_msg)
    assert_empty @notify_h.calls
  end
end
