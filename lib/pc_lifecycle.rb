# Bring the PC-side backends up and down through launchd. Never reuses a
# running process: `up` always ends with jobs launchd started just now.
require "fileutils"
require_relative "launch_agent"

class PcLifecycle
  class Error < StandardError; end

  SIDECAR_WAIT_S = 15
  DAEMON_WAIT_S  = 30   # BLE scan + GATT discovery takes ~13s
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
    @clock    = clock_fn  || -> { Time.now }
  end

  def up
    # launchd does not create StandardOutPath's parent.
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
      # A plist left behind loads again at the next login.
      File.unlink(path) if File.exist?(path)
    end
  end

  private

  # bootout then bootstrap, never kickstart: kickstart reuses the cached plist.
  def start(job, port)
    label = job["Label"]
    @runner.call("launchctl", "bootout", domain(label))
    # bootout returns before the label leaves the domain; bootstrapping too
    # early fails with "Bootstrap failed: 5".
    unless wait_until_unloaded(label)
      raise Error, "#{label} was still loaded #{UNLOAD_WAIT_S}s after bootout " \
                   "(`launchctl print #{domain(label)}`)"
    end
    # A port still held after bootout belongs to something launchd does not manage.
    holder = @releaser.call(port, RELEASE_WAIT_S)
    if holder
      raise Error, "port #{port} is still held #{RELEASE_WAIT_S}s after booting out #{label}, " \
                   "so a process outside launchd owns it. Stop it, then run pc:up again. " \
                   "If the pid below is the job that was just booted out, it is still shutting " \
                   "down — rerun pc:up.\n#{holder}"
    end
    # Write the plist only once bootstrap can succeed; a leftover loads at next login.
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

  # nil once nothing listens; otherwise lsof's line for who still does.
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
    # A wedged daemon accepts TCP and never answers DRb.
    Timeout.timeout(STATUS_WAIT_S) do
      DRb::DRbObject.new_with_uri("druby://127.0.0.1:#{port}").status
    end
  rescue StandardError
    nil
  end
end
