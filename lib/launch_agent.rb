# LaunchAgent job definitions. Pure data: nothing is read from the ambient environment.
require "json"
require "fileutils"

# Builds launchd job definitions and writes them as plists for the PC daemon and sidecar.
module LaunchAgent
  LABEL_PREFIX = "com.bash0c7.stackchan"

  # Returns the launchd label of the daemon job, namespaced when ns is given.
  #: (?String? ns) -> String
  def self.daemon_label(ns = nil)
    ns ? "#{LABEL_PREFIX}-#{ns}-daemon" : "#{LABEL_PREFIX}-daemon"
  end

  # Returns the launchd label of the sidecar job, namespaced when ns is given.
  #: (?String? ns) -> String
  def self.sidecar_label(ns = nil)
    ns ? "#{LABEL_PREFIX}-#{ns}-sidecar" : "#{LABEL_PREFIX}-sidecar"
  end

  # launchd is an acceptable responsible process for TCC; a shell fork/exec is not.
  # Returns the job hash that runs the PicoRuby daemon from the signed app bundle.
  #: (root: String, vm_app: String, port: Integer, sidecar_port: Integer, prefix: String, ble_fake: bool, logdir: String, ?ns: String?) -> Hash[String, untyped]
  def self.daemon_job(root:, vm_app:, port:, sidecar_port:, prefix:, ble_fake:, logdir:, ns: nil)
    args = [File.join(vm_app, "Contents", "MacOS", "picoruby"),
            File.join(root, "pc", "stackchan-pico", "app", "boot_daemon.rb"),
            root, port.to_s, ble_fake ? "fake" : prefix, sidecar_port.to_s]
    job(daemon_label(ns), args, logdir, "daemon")
  end

  # launchd runs no login shell: absolute ruby + RUBYOPT instead of bundle exec.
  # Returns the job hash that runs the CRuby sidecar with an absolute ruby.
  #: (root: String, ruby: String, port: Integer, stub: bool, logdir: String, ?ns: String?) -> Hash[String, untyped]
  def self.sidecar_job(root:, ruby:, port:, stub:, logdir:, ns: nil)
    env = {
      "BUNDLE_GEMFILE" => File.join(root, "pc", "stackchan", "Gemfile"),
      "RUBYOPT"        => "-rbundler/setup",
    }
    env["STACKCHAN_SIDECAR_STUB"] = "1" if stub
    args = [ruby, File.join(root, "pc", "sidecar", "sidecar.rb"), port.to_s]
    job(sidecar_label(ns), args, logdir, "sidecar").merge("EnvironmentVariables" => env)
  end

  # Returns the common job hash: label, arguments, run at load, restart on abnormal exit, log paths.
  #: (String label, Array[String] args, String logdir, String log_basename) -> Hash[String, untyped]
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

  # plutil does the XML escaping.
  # Writes the job as an XML plist named after its label under dir and returns the path.
  # Raises RuntimeError when plutil fails.
  #: (Hash[String, untyped] job, dir: String) -> String
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
