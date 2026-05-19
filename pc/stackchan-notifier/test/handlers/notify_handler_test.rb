require "helper"
require "stackchan_notifier/handlers/notify_handler"
require "stackchan_notifier/notify_motion_table"

# Minimal stub for ts.write capture
class FakeTupleSpace
  attr_reader :written
  def initialize; @written = []; end
  def write(tuple); @written << tuple; end
end

class NotifyHandlerTest < Test::Unit::TestCase
  def setup
    @client  = FakeBleClient.new
    @ts      = FakeTupleSpace.new
    @sleeps  = []
    @sleep_fn = ->(s) { @sleeps << s }
    @ctx     = { ts: @ts, restore_sleep_fn: @sleep_fn }
    @handler = StackchanNotifier::Handlers::NotifyHandler.new
  end

  def test_face_led_motion_when_not_silent
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x00FFFF, :blink],
        right: [0x000000, :solid],
        duration: nil,
        silent: false,
      },
      ctx: @ctx,
    )
    assert_equal 1, @client.sent.size
    cmds = @client.sent[0]
    assert_equal({ kind: :face, name: :joy }, cmds[0])
    assert_equal({ kind: :led, form: :hsb, value: 0x00FFFF, side: :left,  mode: :blink }, cmds[1])
    assert_equal({ kind: :led, form: :hsb, value: 0x000000, side: :right, mode: :solid }, cmds[2])
    # joy motion: yaw 0, pitch 600, time_ms 250
    assert_equal({ kind: :head, yaw: 0, pitch: 600, time_ms: 250, velocity: nil }, cmds[3])
    assert_equal 4, cmds.size
  end

  def test_face_led_only_when_silent
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x00FFFF, :blink],
        right: [0x000000, :solid],
        duration: nil,
        silent: true,
      },
      ctx: @ctx,
    )
    cmds = @client.sent[0]
    assert_equal 3, cmds.size
    assert(cmds.none? { |c| c[:kind] == :head }, "expected no :head command when silent")
  end

  def test_unknown_face_skips_motion
    @handler.deliver(
      client: @client,
      params: {
        face: :bogus,
        left: [0x000000, :solid],
        right: [0x000000, :solid],
        duration: nil,
        silent: false,
      },
      ctx: @ctx,
    )
    cmds = @client.sent[0]
    # face is still attempted (the firmware decides), but no :head appended
    assert(cmds.none? { |c| c[:kind] == :head }, "expected no :head for unknown face")
  end

  def test_restore_tuple_written_after_duration_when_not_silent
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x00FFFF, :solid],
        right: [0x000000, :solid],
        duration: 2,
        silent: false,
      },
      ctx: @ctx,
    )
    # restore thread runs in background; wait for the write
    wait_until(timeout: 1.0) { !@ts.written.empty? }
    assert_equal 1, @ts.written.size
    restore = @ts.written[0]
    assert_equal :cmd, restore[0]
    assert_equal :notify, restore[1]
    assert_equal :neutral, restore[2][:face]
    assert_equal [0x000000, :solid], restore[2][:left]
    assert_equal [0x000000, :solid], restore[2][:right]
    assert_equal false, restore[2][:silent]   # silent preserved
    assert_nil restore[2][:duration]          # restore itself has no further restore
    assert_equal [2], @sleeps                 # restore_sleep_fn called with duration
  end

  def test_restore_preserves_silent_flag
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x000000, :solid],
        right: [0x000000, :solid],
        duration: 1,
        silent: true,
      },
      ctx: @ctx,
    )
    wait_until(timeout: 1.0) { !@ts.written.empty? }
    assert_equal true, @ts.written[0][2][:silent]
  end

  def test_second_deliver_cancels_pending_restore
    # First deliver schedules a restore that sleeps for 5 seconds — long enough
    # that the second deliver's cancel can race in before it fires.
    slow_sleep_holds = []
    slow_sleep_fn = ->(s) {
      slow_sleep_holds << s
      sleep s   # actual sleep so the kill can interrupt
    }
    ctx = { ts: @ts, restore_sleep_fn: slow_sleep_fn }

    @handler.deliver(
      client: @client,
      params: {
        face: :joy, left: [0,:solid], right: [0,:solid],
        duration: 5, silent: false,
      },
      ctx: ctx,
    )
    sleep 0.05   # let restore thread start sleeping

    @handler.deliver(
      client: @client,
      params: {
        face: :sad, left: [0,:solid], right: [0,:solid],
        duration: nil, silent: false,
      },
      ctx: ctx,
    )

    sleep 0.1
    # Original restore was killed before it could ts.write
    assert_empty @ts.written, "first restore should have been cancelled before writing"
  end
end
