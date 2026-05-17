require_relative "helper"
require "stackchan_notifier"
require "stackchan_notifier/tuple_space4ractor"
require "stackchan_notifier/worker"
require "stackchan_ble_client"

class WorkerTest < Test::Unit::TestCase
  def setup
    @ts      = StackchanNotifier::TupleSpace4Ractor.new
    @client  = FakeBleClient.new
    @sleeps  = []
    @worker  = build_worker
  end

  def teardown
    @worker.shutdown(timeout: 2.0)
  end

  # Helper: build a 7-element notify tuple.
  def notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid], duration: nil)
    [:notify, face, left[0], left[1], right[0], right[1], duration]
  end

  def test_takes_single_tuple_and_sends_combo
    @worker.start
    @ts.write(notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid]))

    wait_until { @client.sent.size == 1 }

    commands = @client.sent.first
    assert_equal({ kind: :face, name: :smile }, commands[0])
    assert_equal(
      { kind: :led, form: :hsb, value: 0x00FF00, side: :left, mode: :solid },
      commands[1]
    )
    assert_equal(
      { kind: :led, form: :hsb, value: 0x00FF00, side: :right, mode: :solid },
      commands[2]
    )
  end

  def test_drains_latest_when_many_tuples_queued_before_start
    @ts.write(notify_tuple(face: :neutral, left: [0x111111, :off],   right: [0x111111, :off]))
    @ts.write(notify_tuple(face: :smile,   left: [0x222222, :solid], right: [0x222222, :solid]))
    @ts.write(notify_tuple(face: :joy,     left: [0x333333, :blink], right: [0x333333, :blink]))

    @worker.start
    wait_until { @client.sent.size >= 1 }
    # Give the worker a moment to confirm it does NOT send more.
    sleep 0.1

    assert_equal 1, @client.sent.size, "drain should collapse to a single send"
    commands = @client.sent.first
    assert_equal :joy, commands[0][:name]
    assert_equal 0x333333, commands[1][:value]
    assert_equal :blink, commands[1][:mode]
    assert_equal :left, commands[1][:side]
  end

  def test_reconnects_after_send_failure
    fail_once = true
    @client.on_send do |_builder|
      if fail_once
        fail_once = false
        raise StackchanBleClient::ConnectionError, "synthetic disconnect"
      end
    end

    @worker.start
    @ts.write(notify_tuple(face: :smile, left: [0xAAAAAA, :solid], right: [0xAAAAAA, :solid]))
    wait_until { @client.connect_count >= 2 }   # 1st connect + 1 reconnect

    # With retry-slot: the failed :smile tuple is retried first (sent.size becomes 1),
    # then the :joy tuple is processed (sent.size becomes 2).
    @ts.write(notify_tuple(face: :joy, left: [0xBBBBBB, :blink], right: [0xBBBBBB, :blink]))
    wait_until { @client.sent.size == 2 }

    last = @client.sent.last
    assert_equal :joy, last[0][:name]
    assert_equal 0xBBBBBB, last[1][:value]
    assert @client.disconnect_count >= 1, "disconnect should be invoked during recovery"
  end

  def test_backoff_when_initial_connect_fails
    remaining_failures = 2
    @client.on_connect do |_|
      if remaining_failures > 0
        remaining_failures -= 1
        raise StackchanBleClient::ConnectionError, "no device"
      end
    end

    @worker.start
    @ts.write(notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid]))

    wait_until { @client.connect_count >= 3 && @client.sent.size == 1 }

    assert_equal [0.01, 0.02], @sleeps.first(2),
      "backoff schedule should follow the configured array in order"
  end

  def test_shutdown_unblocks_take
    @worker.start
    sleep 0.05  # let worker reach the blocking take
    t0 = Time.now
    @worker.shutdown(timeout: 2.0)
    elapsed = Time.now - t0
    assert elapsed < 1.0, "shutdown should return promptly (elapsed=#{elapsed.round(3)}s)"
    refute @worker.thread, "thread should be cleared after shutdown"
  end

  def test_send_failure_retries_once_after_reconnect
    attempts = []
    @client.on_send { |_b| attempts << :tried; raise StackchanBleClient::ConnectionError, "transient" if attempts.size == 1 }
    worker = build_worker
    worker.start

    @ts.write(notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid]))

    wait_until { attempts.size == 2 }
    assert_equal 2, attempts.size, "tuple should be re-delivered after first failure"
    assert_equal 2, @client.connect_count, "worker should have reconnected once"

    worker.shutdown
  end

  def test_send_failure_drops_after_second_failure
    warnings = []
    logger = build_capturing_logger(warnings)
    @client.on_send { |_b| raise StackchanBleClient::ConnectionError, "still broken" }
    worker = build_worker(logger: logger)
    worker.start

    @ts.write(notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid]))

    wait_until { warnings.any? { |w| w.include?("send failed twice; dropping") } }
    assert(warnings.any? { |w| w.include?("send failed twice; dropping") }, "expected drop warning, got #{warnings.inspect}")

    worker.shutdown
  end

  def test_force_reconnect_sentinel_triggers_rescan
    worker = build_worker
    worker.start
    wait_until { @client.connect_count == 1 }

    @ts.write([:notify, :__force_reconnect__, 0, :solid, 0, :solid, nil])

    wait_until { @client.connect_count == 2 }
    assert_equal 2, @client.connect_count, "SIGHUP-equivalent tuple should trigger reconnect"
    assert_equal 1, @client.disconnect_count, "old connection should be torn down"

    worker.shutdown
  end

  def test_newer_tuple_wins_over_pending_retry
    send_args = []
    reconnect_latch = Queue.new
    # Gate the reconnect so we can write the newer tuple before retry runs.
    @client.on_connect { |_| reconnect_latch.pop }
    @client.on_send do |b|
      send_args << b.commands.dup
      raise StackchanBleClient::ConnectionError, "fail once" if send_args.size == 1
    end
    worker = build_worker
    worker.start

    # First connect (non-retry) — release the initial connect gate immediately.
    reconnect_latch << :go

    @ts.write(notify_tuple(face: :smile,     left: [0x00FF00, :solid], right: [0x00FF00, :solid]))  # will fail
    wait_until { send_args.size >= 1 }                          # first attempt failed

    # Reconnect is now gated; write newer tuple into TS before releasing.
    @ts.write(notify_tuple(face: :surprised, left: [0xFF0000, :blink], right: [0xFF0000, :blink]))  # newer tuple arrives during reconnect window
    reconnect_latch << :go                                       # release reconnect

    wait_until { send_args.size >= 2 }
    latest_led = send_args.last.find { |c| c[:kind] == :led }
    assert_equal 0xFF0000, latest_led[:value], "newer tuple should win over retry; got #{latest_led.inspect}"

    worker.shutdown
  end

  def test_force_reconnect_sentinel_drained_during_burst_still_triggers_rescan
    worker = build_worker
    worker.start
    wait_until { @client.connect_count == 1 }

    # Write a burst — the worker's drain_latest will GC the older one.
    # Slip the FORCE_RECONNECT_TUPLE between two notifies so it lands
    # in the drained position, not the initial-take position.
    @ts.write(notify_tuple(face: :smile,     left: [0x00FF00, :solid], right: [0x00FF00, :solid]))
    @ts.write([:notify, :__force_reconnect__, 0, :solid, 0, :solid, nil])
    @ts.write(notify_tuple(face: :surprised, left: [0xFF0000, :blink], right: [0xFF0000, :blink]))

    wait_until { @client.connect_count == 2 }
    assert_equal 2, @client.connect_count, "force-reconnect drained during burst should still trigger reconnect"

    worker.shutdown
  end

  def test_deliver_sends_face_plus_left_led_plus_right_led
    worker = build_worker
    worker.start
    @ts.write(notify_tuple(face: :joy, left: [0xFF0000, :blink], right: [0x000000, :solid]))
    wait_until { @client.sent.size == 1 }
    cmds = @client.sent.first
    assert_equal :joy, cmds[0][:name]
    assert_equal({ kind: :led, form: :hsb, value: 0xFF0000, side: :left,  mode: :blink}, cmds[1])
    assert_equal({ kind: :led, form: :hsb, value: 0x000000, side: :right, mode: :solid}, cmds[2])
    worker.shutdown
  end

  def test_deliver_with_duration_schedules_restore_to_neutral_off
    worker = build_worker(restore_clock: ->(_s) { sleep(0.05) })
    worker.start
    @ts.write(notify_tuple(face: :surprised, left: [0xFF0000, :blink], right: [0xFF0000, :blink], duration: 1))
    wait_until { @client.sent.size == 2 }
    restore_cmds = @client.sent.last
    assert_equal :neutral, restore_cmds[0][:name]
    assert_equal 0x000000, restore_cmds[1][:value]
    assert_equal 0x000000, restore_cmds[2][:value]
    worker.shutdown
  end

  def test_new_tuple_arriving_during_pending_restore_cancels_it
    worker = build_worker(restore_clock: ->(_s) { sleep(5.0) })
    worker.start
    @ts.write(notify_tuple(face: :surprised, left: [0xFF0000, :blink], right: [0xFF0000, :blink], duration: 5))
    wait_until { @client.sent.size == 1 }
    @ts.write(notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid]))
    wait_until { @client.sent.size == 2 }
    sleep 0.5   # well under the 5s restore timer
    # Restore must NOT have fired — sent.size stays 2, not 3
    assert_equal 2, @client.sent.size, "newer tuple should cancel pending restore; saw #{@client.sent.inspect}"
    worker.shutdown
  end

  private

  def build_worker(logger: nil, restore_clock: ->(_s) { sleep(0.01) })
    StackchanNotifier::Worker.new(
      ts:               @ts,
      client_factory:   -> { @client },
      backoff:          [0.01, 0.02, 0.04],
      sleep_fn:         ->(s) { @sleeps << s; sleep(0.001) },
      logger:           logger,
      restore_sleep_fn: restore_clock,
    )
  end

  def wait_until(timeout: 3.0)
    deadline = Time.now + timeout
    until yield
      flunk "condition never satisfied within #{timeout}s" if Time.now > deadline
      sleep 0.01
    end
  end
end
