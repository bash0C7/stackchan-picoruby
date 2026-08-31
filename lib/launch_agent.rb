# LaunchAgent job definitions for the StackChan PC-side backends.
#
# Pure data: every value comes from an argument, never from the ambient
# environment. An ambient STACKCHAN_SIDECAR_STUB leaking into a spawned
# sidecar is what silently muted `say` for 8 days (2026-08-23..08-31), so the
# stub flag reaches a job only when the caller asks for it here.
require "json"
require "fileutils"

module LaunchAgent
  LABEL_PREFIX = "com.bash0c7.stackchan"

  def self.daemon_label(ns = nil)
    ns ? "#{LABEL_PREFIX}-#{ns}-daemon" : "#{LABEL_PREFIX}-daemon"
  end

  def self.sidecar_label(ns = nil)
    ns ? "#{LABEL_PREFIX}-#{ns}-sidecar" : "#{LABEL_PREFIX}-sidecar"
  end

  # The daemon runs the binary inside the signed app bundle. launchd is an
  # acceptable responsible process for TCC, so CoreBluetooth works without
  # `open -a` (spike 2026-08-31); a plain shell fork/exec still does not.
  def self.daemon_job(root:, vm_app:, port:, prefix:, ble_fake:, logdir:, ns: nil)
    boot = ble_fake ? "boot_daemon.rb" : "boot_daemon_real.rb"
    args = [File.join(vm_app, "Contents", "MacOS", "picoruby"),
            File.join(root, "pc", "stackchan-pico", "app", boot),
            root, port.to_s]
    args << prefix unless ble_fake   # boot_daemon.rb takes only <root> <port>
    job(daemon_label(ns), args, logdir, "daemon")
  end

  # launchd does not run a login shell, so `bundle exec` is unavailable and an
  # rbenv shim would not resolve: the caller passes an absolute ruby
  # (RbConfig.ruby) and bundler is entered through RUBYOPT instead.
  def self.sidecar_job(root:, ruby:, port:, stub:, logdir:, ns: nil)
    env = {
      "BUNDLE_GEMFILE" => File.join(root, "pc", "stackchan", "Gemfile"),
      "RUBYOPT"        => "-rbundler/setup",
    }
    env["STACKCHAN_SIDECAR_STUB"] = "1" if stub
    args = [ruby, File.join(root, "pc", "sidecar", "sidecar.rb"), port.to_s]
    job(sidecar_label(ns), args, logdir, "sidecar").merge("EnvironmentVariables" => env)
  end

  def self.job(label, args, logdir, log_basename)
    log = File.join(logdir, "#{log_basename}.log")
    {
      "Label"             => label,
      "ProgramArguments"  => args,
      "RunAtLoad"         => true,
      # Restart on abnormal exit only: a daemon that exits 0 because the robot
      # is switched off must not respawn forever.
      "KeepAlive"         => { "SuccessfulExit" => false },
      "StandardOutPath"   => log,
      "StandardErrorPath" => log,
    }
  end

  # plutil does the XML escaping, so a path containing plist metacharacters
  # cannot corrupt the file.
  def self.write(job, dir:)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{job['Label']}.plist")
    json = "#{path}.json"
    File.write(json, JSON.generate(job))
    unless system("plutil", "-convert", "xml1", "-o", path, json)
      raise "plutil failed to convert #{json}"
    end
    File.unlink(json)
    path
  end
end
