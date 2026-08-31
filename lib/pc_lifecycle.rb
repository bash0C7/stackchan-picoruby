# Bring the PC-side backends up and down through launchd.
#
# There is deliberately no "reuse what is already running" path: deciding
# whether a resident process was usable is what produced all three of the
# 2026-08-31 incidents (a busy daemon killed as wedged, an 8-day-stale stub
# sidecar, a healthy daemon killed over one transient DRb error). `up` always
# ends with processes launchd started just now.
require "launch_agent"

class PcLifecycle
  class Error < StandardError; end

  SIDECAR_WAIT_S = 15
  DAEMON_WAIT_S  = 30   # BLE scan + GATT discovery; measured 13s on 2026-08-31

  def initialize(config, dir:, runner: nil, waiter: nil, verifier: nil)
    @c        = config
    @dir      = dir
    @runner   = runner   || method(:run_command)
    @waiter   = waiter   || method(:wait_for_port)
    @verifier = verifier || method(:daemon_status)
  end

  def up
    sidecar = LaunchAgent.sidecar_job(root: @c[:root], ruby: @c[:ruby], port: @c[:sidecar_port],
                                      stub: @c[:stub], logdir: @c[:logdir], ns: @c[:ns])
    daemon  = LaunchAgent.daemon_job(root: @c[:root], vm_app: @c[:vm_app], port: @c[:port],
                                     prefix: @c[:prefix], ble_fake: @c[:ble_fake],
                                     logdir: @c[:logdir], ns: @c[:ns])
    start(sidecar)
    unless @waiter.call(@c[:sidecar_port], SIDECAR_WAIT_S)
      raise Error, "sidecar did not listen on #{@c[:sidecar_port]} within #{SIDECAR_WAIT_S}s " \
                   "(see #{@c[:logdir]}/sidecar.log, `launchctl print gui/#{Process.uid}/#{sidecar['Label']}`)"
    end
    start(daemon)
    unless @waiter.call(@c[:port], DAEMON_WAIT_S)
      raise Error, "daemon did not listen on #{@c[:port]} within #{DAEMON_WAIT_S}s " \
                   "(see #{@c[:logdir]}/daemon.log, `launchctl print gui/#{Process.uid}/#{daemon['Label']}`)"
    end
    status = @verifier.call(@c[:port])
    unless status && status[:ble_connected]
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

  def start(job)
    path  = LaunchAgent.write(job, dir: @dir)
    label = job["Label"]
    _, loaded = @runner.call("launchctl", "print", domain(label))
    if loaded
      @runner.call("launchctl", "kickstart", "-k", domain(label))
    else
      @runner.call("launchctl", "bootstrap", "gui/#{Process.uid}", path)
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

  def daemon_status(port)
    require "drb"
    DRb.start_service
    DRb::DRbObject.new_with_uri("druby://127.0.0.1:#{port}").status
  rescue StandardError
    nil
  end
end
