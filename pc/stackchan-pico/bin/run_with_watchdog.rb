#!/usr/bin/env ruby
# Wrap a command with a hard timeout; on timeout, capture a diagnostic
# incident bundle (sample + ps + log tail) for the TARGET process before
# force-killing both the wrapped command and the target. The target is the
# daemon for every label except "sidecar_preflight" (bin/stackchan's
# probe_sidecar), which targets the sidecar instead -- a sidecar-probe
# timeout must not collaterally kill an unrelated, healthy, BLE-connected
# daemon (see docs/superpowers/specs/2026-08-11-sidecar-call-timeout-design.md).
# A daemon wedge (OS-thread-level, e.g. inside a blocking CoreBluetooth
# call) survives graceful shutdown -- see
# docs/superpowers/specs/2026-08-11-daemon-hang-watchdog-design.md -- so
# this always treats a timeout as a suspected wedge, not just a slow
# command.
#
# Usage: run_with_watchdog.rb <timeout_seconds> <label> <command...>
# Exit: propagates the command's own exit status, or 124 on timeout.
require "timeout"
require "fileutils"

secs  = ARGV.shift.to_i
label = ARGV.shift
cmd   = ARGV
abort "usage: run_with_watchdog.rb <timeout_seconds> <label> <command...>" if cmd.empty?
abort "run_with_watchdog.rb: timeout_seconds must be a positive integer, got #{secs}" if secs <= 0

LOGDIR = ENV["STACKCHAN_LOGDIR"] || "/tmp/stackchan-pico"

def daemon_pid
  real = `pgrep -f "picoruby.*boot_daemon_real.rb"`.split("\n").first
  return real if real && !real.empty?
  fake = `pgrep -f "picoruby.*boot_daemon.rb"`.split("\n").first
  fake && !fake.empty? ? fake : nil
end

def sidecar_pid
  pid = `pgrep -f "ruby.*pc/sidecar/sidecar\\.rb"`.split("\n").first
  pid && !pid.empty? ? pid : nil
end

def target_pid_for(label)
  label == "sidecar_preflight" ? sidecar_pid : daemon_pid
end

def target_log_for(label)
  label == "sidecar_preflight" ? "sidecar.log" : "daemon.log"
end

def capture_incident(label, secs, cmd, child_pid)
  incident_dir = File.join(LOGDIR, "hang-incidents")
  FileUtils.mkdir_p(incident_dir)
  tpid = target_pid_for(label)
  path = File.join(incident_dir, "#{Time.now.to_i}-#{label}.log")
  File.open(path, "w") do |f|
    f.puts "label=#{label} timeout_s=#{secs} cmd=#{cmd.join(' ')} child_pid=#{child_pid} target_pid=#{tpid || '(none found)'}"
    f.puts "--- ps (child) ---"
    f.puts `ps -o pid,etime,state,command -p #{child_pid} 2>&1`
    if tpid
      f.puts "--- ps (target) ---"
      f.puts `ps -o pid,etime,state,command -p #{tpid} 2>&1`
      f.puts "--- sample (target, 2s) ---"
      f.puts `sample #{tpid} 2 2>&1`
    end
    log_path = File.join(LOGDIR, target_log_for(label))
    if File.exist?(log_path)
      f.puts "--- #{target_log_for(label)} tail ---"
      f.puts `tail -n 50 #{log_path} 2>&1`
    end
  end
  warn "[stackchan] #{label} timed out after #{secs}s -- diagnostics saved to #{path}"
  tpid
end

pid = Process.spawn(*cmd, out: $stdout, err: $stderr)
begin
  Timeout.timeout(secs) { Process.wait(pid) }
  status = $?.exitstatus || 1
  # A fast (non-hanging) failure still means the daemon/sidecar the caller
  # was talking to came back wedged or already dead -- capture the same
  # diagnostic bundle as the timeout path so it isn't silently lost. Only
  # the trigger differs; capture_incident's own behavior is unchanged.
  capture_incident(label, secs, cmd, pid) if status != 0
  exit status
rescue Timeout::Error
  tpid = capture_incident(label, secs, cmd, pid)
  begin
    Process.kill("KILL", pid)
  rescue StandardError
  end
  begin
    Process.wait(pid)
  rescue StandardError
  end
  if tpid
    begin
      Process.kill("KILL", tpid.to_i)
    rescue StandardError
    end
  end
  warn "[stackchan] #{label}: target process killed (pid #{tpid || 'unknown'}), will respawn on next call"
  exit 124
end
