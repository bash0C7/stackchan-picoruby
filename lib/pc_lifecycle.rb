# Bring the PC-side backends up and down through launchd.
#
# There is deliberately no "reuse what is already running" path: deciding
# whether a resident process was usable is what produced all three of the
# 2026-08-31 incidents (a busy daemon killed as wedged, an 8-day-stale stub
# sidecar, a healthy daemon killed over one transient DRb error). `up` always
# ends with processes launchd started just now, from the plist just written.
require "fileutils"
require_relative "launch_agent"

class PcLifecycle
  class Error < StandardError; end

  SIDECAR_WAIT_S = 15
  DAEMON_WAIT_S  = 30   # BLE scan + GATT discovery; measured 13s on 2026-08-31
  UNLOAD_WAIT_S  = 10   # grace for bootout to actually leave the launchd domain
  RELEASE_WAIT_S = 10   # grace for a booted-out job to let go of its port
  STATUS_WAIT_S  = 10   # a wedged daemon accepts TCP but never answers DRb

  def initialize(config, dir:, runner: nil, waiter: nil, releaser: nil, verifier: nil,
                 sleep_fn: nil, clock_fn: nil)
    @c        = config
    @dir      = dir
    @runner   = runner   || method(:run_command)
    @waiter   = waiter   || method(:wait_for_port)
    @releaser = releaser || method(:wait_for_port_release)
    @verifier = verifier || method(:daemon_status)
    @sleep_fn = sleep_fn  || ->(s) { sleep(s) }
    # `wait_until_unloaded` below is exercised through its real
    # implementation in tests (unlike wait_for_port / wait_for_port_release,
    # which are always fully replaced by waiter:/releaser:), so its wall
    # clock has to be fakeable too, or a test that forces the timeout path
    # would burn UNLOAD_WAIT_S of real time and CPU to prove it.
    @clock    = clock_fn  || -> { Time.now }
  end

  def up
    # launchd does not create the parent of StandardOutPath. Without this the
    # job fails to spawn at all, and the timeout below points the operator at a
    # log file that was never created.
    FileUtils.mkdir_p(@c[:logdir])
    vm = File.join(@c[:vm_app], "Contents", "MacOS", "picoruby")
    unless File.exist?(vm)
      raise Error, "#{vm} is missing — run `bundle exec rake pc:app_bundle` first. " \
                   "The daemon has to run from the signed bundle or macOS denies it CoreBluetooth."
    end

    sidecar = LaunchAgent.sidecar_job(root: @c[:root], ruby: @c[:ruby], port: @c[:sidecar_port],
                                      stub: @c[:stub], logdir: @c[:logdir], ns: @c[:ns])
    daemon  = LaunchAgent.daemon_job(root: @c[:root], vm_app: @c[:vm_app], port: @c[:port],
                                     prefix: @c[:prefix], ble_fake: @c[:ble_fake],
                                     logdir: @c[:logdir], ns: @c[:ns])

    start(sidecar, @c[:sidecar_port])
    unless @waiter.call(@c[:sidecar_port], SIDECAR_WAIT_S)
      raise Error, "sidecar did not listen on #{@c[:sidecar_port]} within #{SIDECAR_WAIT_S}s " \
                   "(see #{@c[:logdir]}/sidecar.log, `launchctl print gui/#{Process.uid}/#{sidecar['Label']}`)"
    end
    start(daemon, @c[:port])
    unless @waiter.call(@c[:port], DAEMON_WAIT_S)
      raise Error, "daemon did not listen on #{@c[:port]} within #{DAEMON_WAIT_S}s " \
                   "(see #{@c[:logdir]}/daemon.log, `launchctl print gui/#{Process.uid}/#{daemon['Label']}`)"
    end

    status = @verifier.call(@c[:port])
    if status.nil?
      raise Error, "daemon on #{@c[:port]} is listening but did not answer status within " \
                   "#{STATUS_WAIT_S}s (see #{@c[:logdir]}/daemon.log)"
    end
    unless status[:ble_connected]
      raise Error, "daemon is listening but not connected to the robot: #{status.inspect}"
    end
    status
  end

  def down
    [LaunchAgent.sidecar_label(@c[:ns]), LaunchAgent.daemon_label(@c[:ns])].each do |label|
      @runner.call("launchctl", "bootout", domain(label))
      path = File.join(@dir, "#{label}.plist")
      # Remove the definition too: a plist left behind is loaded again at the
      # next login, so "down" would silently undo itself.
      File.unlink(path) if File.exist?(path)
    end
  end

  private

  # Always bootout then bootstrap, never kickstart. launchd caches a job's
  # definition when it is bootstrapped; `kickstart -k` restarts the process from
  # that cached copy and never rereads the plist (measured 2026-08-31: a job
  # bootstrapped with PROBE_VALUE=first still ran `first` after its plist had
  # been rewritten to `second`). Reusing a loaded job would restart yesterday's
  # configuration — the stale stub sidecar this design exists to prevent,
  # reappearing inside the fix.
  def start(job, port)
    label = job["Label"]
    @runner.call("launchctl", "bootout", domain(label))
    # bootout returns before launchd has finished unloading the service, and
    # bootstrapping while the domain still holds the label fails with
    # "Bootstrap failed: 5: Input/output error" (observed 2026-08-31 on the
    # second pc:up of the session). This use of `print` is not the old
    # kickstart branch returning: it confirms absence, and is never used to
    # decide whether to reuse a job that is still loaded.
    unless wait_until_unloaded(label)
      raise Error, "#{label} was still loaded #{UNLOAD_WAIT_S}s after bootout " \
                   "(`launchctl print #{domain(label)}`)"
    end
    # A port still held once our own job is gone belongs to something launchd
    # does not manage. Refuse: otherwise the new job dies on EADDRINUSE and the
    # port check passes against the squatter, reporting success for a process we
    # did not start.
    holder = @releaser.call(port, RELEASE_WAIT_S)
    if holder
      raise Error, "port #{port} is still held #{RELEASE_WAIT_S}s after booting out #{label}, " \
                   "so a process outside launchd owns it. Stop it, then run pc:up again. " \
                   "If the pid below is the job that was just booted out, it is still shutting " \
                   "down — rerun pc:up.\n#{holder}"
    end
    # Write the definition only once we know it can be bootstrapped: a plist
    # left in ~/Library/LaunchAgents by a failed `up` is loaded at the next
    # login, starting a backend that never came up successfully.
    path = LaunchAgent.write(job, dir: @dir)
    out, ok = @runner.call("launchctl", "bootstrap", "gui/#{Process.uid}", path)
    unless ok
      File.unlink(path) if File.exist?(path)
      raise Error, "launchctl bootstrap failed for #{label} (#{path}): #{out.to_s.strip}"
    end
  end

  def domain(label)
    "gui/#{Process.uid}/#{label}"
  end

  def run_command(*argv)
    out = IO.popen(argv, err: [:child, :out], &:read)
    [out, $?.success?]
  end

  def wait_for_port(port, timeout_s)
    require "socket"
    deadline = Time.now + timeout_s
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", port).close
        return true
      rescue StandardError
        sleep 0.25
      end
    end
    false
  end

  def wait_until_unloaded(label)
    deadline = @clock.call + UNLOAD_WAIT_S
    loop do
      _, loaded = @runner.call("launchctl", "print", domain(label))
      return true unless loaded
      return false if @clock.call >= deadline
      @sleep_fn.call(0.25)
    end
  end

  # nil once nothing listens on the port; otherwise lsof's description of who
  # still does, so the operator is handed a PID rather than "it didn't work".
  def wait_for_port_release(port, timeout_s)
    deadline = Time.now + timeout_s
    loop do
      holder = IO.popen(["lsof", "-nP", "-iTCP:#{port}", "-sTCP:LISTEN"],
                        err: [:child, :out], &:read).to_s
      return nil unless holder.include?("LISTEN")
      return holder if Time.now >= deadline
      sleep 0.25
    end
  end

  def daemon_status(port)
    require "drb"
    require "timeout"
    DRb.start_service
    # A daemon can accept TCP and never answer DRb (observed 2026-08-11). Without
    # this bound, `rake pc:up` hangs with no output and no way to tell that from
    # a slow BLE connect.
    Timeout.timeout(STATUS_WAIT_S) do
      DRb::DRbObject.new_with_uri("druby://127.0.0.1:#{port}").status
    end
  rescue StandardError
    nil
  end
end
