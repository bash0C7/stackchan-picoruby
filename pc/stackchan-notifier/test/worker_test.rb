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
    @worker  = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      backoff:        [0.01, 0.02, 0.04],
      sleep_fn:       ->(s) { @sleeps << s; sleep(0.001) }
    )
  end

  def teardown
    @worker.shutdown(timeout: 2.0)
  end

  def test_takes_single_tuple_and_sends_combo
    @worker.start
    @ts.write([:notify, :smile, 0x00FF00, :solid, :both])

    wait_until { @client.sent.size == 1 }

    commands = @client.sent.first
    assert_equal({ kind: :face, name: :smile }, commands[0])
    assert_equal(
      { kind: :led, form: :hsb, value: 0x00FF00, side: :both, mode: :solid },
      commands[1]
    )
  end

  def test_drains_latest_when_many_tuples_queued_before_start
    @ts.write([:notify, :neutral, 0x111111, :off,    :both])
    @ts.write([:notify, :smile,   0x222222, :solid,  :left])
    @ts.write([:notify, :joy,     0x333333, :blink,  :right])

    @worker.start
    wait_until { @client.sent.size >= 1 }
    # Give the worker a moment to confirm it does NOT send more.
    sleep 0.1

    assert_equal 1, @client.sent.size, "drain should collapse to a single send"
    commands = @client.sent.first
    assert_equal :joy, commands[0][:name]
    assert_equal 0x333333, commands[1][:value]
    assert_equal :blink, commands[1][:mode]
    assert_equal :right, commands[1][:side]
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
    @ts.write([:notify, :smile, 0xAAAAAA, :solid, :both])
    wait_until { @client.connect_count >= 2 }   # 1st connect + 1 reconnect

    # With retry-slot: the failed :smile tuple is retried first (sent.size becomes 1),
    # then the :joy tuple is processed (sent.size becomes 2).
    @ts.write([:notify, :joy, 0xBBBBBB, :blink, :both])
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
    @ts.write([:notify, :smile, 0x00FF00, :solid, :both])

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

    @ts.write([:notify, :smile, 0x00FF00, :solid, :both])

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

    @ts.write([:notify, :smile, 0x00FF00, :solid, :both])

    wait_until { warnings.any? { |w| w.include?("send failed twice; dropping") } }
    assert(warnings.any? { |w| w.include?("send failed twice; dropping") }, "expected drop warning, got #{warnings.inspect}")

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

    @ts.write([:notify, :smile,     0x00FF00, :solid, :both])  # will fail
    wait_until { send_args.size >= 1 }                          # first attempt failed

    # Reconnect is now gated; write newer tuple into TS before releasing.
    @ts.write([:notify, :surprised, 0xFF0000, :blink, :left])   # newer tuple arrives during reconnect window
    reconnect_latch << :go                                       # release reconnect

    wait_until { send_args.size >= 2 }
    latest_led = send_args.last.find { |c| c[:kind] == :led }
    assert_equal 0xFF0000, latest_led[:value], "newer tuple should win over retry; got #{latest_led.inspect}"

    worker.shutdown
  end

  private

  def build_worker(logger: nil)
    StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      backoff:        [0.01, 0.02, 0.04],
      sleep_fn:       ->(s) { @sleeps << s; sleep(0.001) },
      logger:         logger
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
