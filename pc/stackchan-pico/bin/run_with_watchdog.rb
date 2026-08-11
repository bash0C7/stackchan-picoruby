#!/usr/bin/env ruby
# Wrap a command with a hard timeout; on timeout, capture a diagnostic
# incident bundle (sample + ps + daemon.log tail) for the stackchan-pico
# daemon process before force-killing both the wrapped command and the
# daemon itself. A daemon wedge (OS-thread-level, e.g. inside a blocking
# CoreBluetooth call) survives graceful shutdown -- see
# docs/superpowers/specs/2026-08-11-daemon-hang-watchdog-design.md -- so
# this always treats a timeout as a suspected daemon wedge, not just a
# slow command.
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

def capture_incident(label, secs, cmd, child_pid)
  incident_dir = File.join(LOGDIR, "hang-incidents")
  FileUtils.mkdir_p(incident_dir)
  dpid = daemon_pid
  path = File.join(incident_dir, "#{Time.now.to_i}-#{label}.log")
  File.open(path, "w") do |f|
    f.puts "label=#{label} timeout_s=#{secs} cmd=#{cmd.join(' ')} child_pid=#{child_pid} daemon_pid=#{dpid || '(none found)'}"
    f.puts "--- ps (child) ---"
    f.puts `ps -o pid,etime,state,command -p #{child_pid} 2>&1`
    if dpid
      f.puts "--- ps (daemon) ---"
      f.puts `ps -o pid,etime,state,command -p #{dpid} 2>&1`
      f.puts "--- sample (daemon, 2s) ---"
      f.puts `sample #{dpid} 2 2>&1`
    end
    daemon_log = File.join(LOGDIR, "daemon.log")
    if File.exist?(daemon_log)
      f.puts "--- daemon.log tail ---"
      f.puts `tail -n 50 #{daemon_log} 2>&1`
    end
  end
  warn "[stackchan] #{label} timed out after #{secs}s -- diagnostics saved to #{path}"
  dpid
end

pid = Process.spawn(*cmd, out: $stdout, err: $stderr)
begin
  Timeout.timeout(secs) { Process.wait(pid) }
  exit($?.exitstatus || 1)
rescue Timeout::Error
  dpid = capture_incident(label, secs, cmd, pid)
  begin
    Process.kill("KILL", pid)
  rescue StandardError
  end
  begin
    Process.wait(pid)
  rescue StandardError
  end
  if dpid
    begin
      Process.kill("KILL", dpid.to_i)
    rescue StandardError
    end
  end
  warn "[stackchan] #{label}: daemon killed (pid #{dpid || 'unknown'}), will respawn on next call"
  exit 124
end
