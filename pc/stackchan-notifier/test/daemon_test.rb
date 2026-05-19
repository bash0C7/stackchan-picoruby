require_relative "helper"
require "logger"
require "drb/drb"
require "drb/unix"
require "stackchan_notifier/daemon"

class DaemonTest < Test::Unit::TestCase
  def setup
    @socket  = "/tmp/stackchan-notifier-test-#{Process.pid}-#{rand(0xFFFF).to_s(16)}.sock"
    @client  = FakeBleClient.new
    @logger  = Logger.new(File.open(File::NULL, "w"))
    @daemon  = StackchanNotifier::Daemon.new(
      opts:           { socket: @socket, device_name: "Test", name_prefix: nil, log_level: "error" },
      client_factory: -> { @client },
      logger:         @logger,
    )
  end

  def teardown
    @daemon.shutdown
  rescue StandardError
    nil
  ensure
    Signal.trap("HUP", "DEFAULT")
    Signal.trap("INT", "DEFAULT")
    Signal.trap("TERM", "DEFAULT")
    FileUtils.rm_f(@socket)
  end

  def test_start_creates_unix_socket_with_owner_only_permissions
    @daemon.start
    assert File.socket?(@socket), "DRb should create a Unix socket at #{@socket}"
    mode = File.stat(@socket).mode & 0o777
    assert_equal 0o600, mode, "socket should be owner-only (got #{mode.to_s(8)})"
  end

  def test_shutdown_removes_socket_and_stops_worker
    @daemon.start
    @daemon.shutdown
    refute File.exist?(@socket), "socket should be removed after shutdown"
    assert_nil @daemon.worker.thread, "worker thread should be cleared"
  end

  def test_drb_round_trip_in_process_delivers_tuple_to_ble
    @daemon.start
    remote = DRbObject.new_with_uri(@daemon.drb_uri)
    remote.write([:cmd, :notify, {
      face: :smile, left: [0xFF8800, :blink], right: [0x00FF00, :solid],
      duration: nil, silent: true,
    }])

    wait_until { @client.sent.size == 1 }

    cmds = @client.sent.first
    assert_equal :smile,   cmds[0][:name]
    assert_equal 0xFF8800, cmds[1][:value]
    assert_equal :blink,   cmds[1][:mode]
    assert_equal :left,    cmds[1][:side]
    assert_equal 0x00FF00, cmds[2][:value]
    assert_equal :solid,   cmds[2][:mode]
    assert_equal :right,   cmds[2][:side]
  end

  def test_daemon_dispatches_servo_tuple
    @daemon.start
    remote = DRbObject.new_with_uri(@daemon.drb_uri)
    remote.write([:cmd, :servo, { yaw: 100, pitch: 450, time_ms: 200, velocity: nil }])

    wait_until { @client.sent.any? { |s| s.is_a?(Array) && s.any? { |c| c[:kind] == :head } } }

    head_cmd = @client.sent.flatten.find { |c| c.is_a?(Hash) && c[:kind] == :head }
    assert_equal 100, head_cmd[:yaw]
    assert_equal 450, head_cmd[:pitch]
    assert_equal 200, head_cmd[:time_ms]
    assert_nil        head_cmd[:velocity]
  end

  def test_daemon_dispatches_raw_tuple
    @daemon.start
    remote = DRbObject.new_with_uri(@daemon.drb_uri)
    remote.write([:cmd, :raw, { frame: "<F:2>" }])

    wait_until { @client.sent.any? { |s| s.is_a?(Hash) && s[:kind] == :raw_send } }

    raw = @client.sent.find { |s| s.is_a?(Hash) && s[:kind] == :raw_send }
    assert_equal "<F:2>\n", raw[:frame]
  end

  def test_stale_socket_file_is_cleaned_on_start
    FileUtils.touch(@socket)
    # Create a fake "stale socket" by binding then closing — simplest is to use
    # UNIXServer to leave a real socket inode behind, then close.
    require "socket"
    # Ensure the socket file is completely removed before trying to bind
    FileUtils.rm_f(@socket)
    s = UNIXServer.new(@socket)
    s.close
    assert File.socket?(@socket)

    @daemon.start
    assert File.socket?(@socket), "daemon should have re-bound the socket"
  end

  def test_stop_unblocks_wait
    @daemon.start
    waiter = Thread.new { @daemon.wait }
    sleep 0.05
    assert waiter.alive?, "wait should block until stop is signalled"
    @daemon.stop
    joined = waiter.join(1.0)
    assert joined, "wait should return after stop"
  end

  def test_run_with_argv_rejects_invalid_log_level
    stderr = StringIO.new
    code = StackchanNotifier::Daemon.run_with_argv(["--log-level", "verbose"], stderr: stderr)
    assert_equal 2, code
    assert_match(/--log-level/, stderr.string)
  end

  def test_install_signal_handlers_traps_hup_to_force_reconnect
    @daemon.start
    called = 0
    @daemon.worker.define_singleton_method(:force_reconnect) { called += 1 }

    @daemon.install_signal_handlers
    Process.kill("HUP", Process.pid)
    wait_until { called == 1 }

    assert_equal 1, called, "SIGHUP should call worker.force_reconnect"
  end

  # Ruby 4.0 raises ThreadError if Mutex#synchronize is reached from a trap
  # context. `stop` synchronizes on @stop_mutex, so the trap defers to a
  # fresh Thread. Send a real SIGTERM to verify the deferral works and
  # that `wait` unblocks as the side effect of the eventual stop.
  def test_install_signal_handlers_traps_term_via_thread_deferral
    @daemon.start
    @daemon.install_signal_handlers
    waiter = Thread.new { @daemon.wait }
    sleep 0.05
    assert waiter.alive?, "wait should still be blocking before SIGTERM"

    Process.kill("TERM", Process.pid)
    joined = waiter.join(2.0)
    assert joined, "wait should return after SIGTERM-driven stop"
  end

  # Same coverage for SIGINT (Ctrl-C in foreground) — must also clean up
  # cleanly through the deferred Thread instead of bubbling up the default
  # Interrupt and killing the process mid-mutex.
  def test_install_signal_handlers_traps_int_via_thread_deferral
    @daemon.start
    @daemon.install_signal_handlers
    waiter = Thread.new { @daemon.wait }
    sleep 0.05
    assert waiter.alive?, "wait should still be blocking before SIGINT"

    Process.kill("INT", Process.pid)
    joined = waiter.join(2.0)
    assert joined, "wait should return after SIGINT-driven stop"
  end

  private

  def wait_until(timeout: 3.0)
    deadline = Time.now + timeout
    until yield
      flunk "condition never satisfied within #{timeout}s" if Time.now > deadline
      sleep 0.01
    end
  end
end
