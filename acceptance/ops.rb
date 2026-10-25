# What Acceptance::Runner (acceptance/runner.rb) does to the machine: git, rake in the
# checkout, the stackchan CLI, the operator's y/n.
require "fileutils"
require "open3"
require "bundler"
require_relative "../lib/device_lock"

# Host-side acceptance run of the robot.
module Acceptance
  # Everything an acceptance run does to the machine: git, rake, the stackchan CLI and the operator prompt.
  class Ops
    # @rbs @log_dir: String
    # @rbs @device_env: ^() -> Hash[String, String?]
    # @rbs @n: Integer

    DEVICE_TASKS = %w[r2p2:build_flash r2p2:upload_appmrb r2p2:flash_identity r2p2:reset_and_capture r2p2:reset].freeze

    # Creates log_dir; device_env supplies the environment of device-touching rake tasks.
    #: (String log_dir, ?device_env: ^() -> Hash[String, String?]) -> void
    def initialize(log_dir, device_env: -> { {} })
      @log_dir = log_dir
      @device_env = device_env
      @n = 0
      FileUtils.mkdir_p(log_dir)
    end

    # Returns whether path exists, including a dangling symlink.
    #: (String path) -> bool
    def exist?(path) = File.exist?(path) || File.symlink?(path)
    # Returns the bytes of path, or nil when it does not exist.
    #: (String path) -> String?
    def read(path) = File.exist?(path) ? File.binread(path) : nil

    # Runs git in dir and returns [success, combined output, 0].
    #: (String dir, *String args) -> [bool, String, Integer]
    def git(dir, *args)
      out, status = Open3.capture2e("git", "-C", dir, *args)
      [status.success?, out, 0]
    end

    # Streams to the terminal and to one log per call; the caller gets the output
    # and the command's own exit status (no pipe in between).
    # Runs a rake task in dir, holding the esp32 device lock for device tasks. Returns [success, output, 0].
    #: (String dir, *String tasks, ?env: Hash[String, String?], ?bundle: bool, ?limit: Numeric?) -> [bool, String, Integer]
    def rake(dir, *tasks, env: {}, bundle: true, limit: nil)
      return run_rake(dir, *tasks, env: env, bundle: bundle, limit: limit) unless DEVICE_TASKS.include?(tasks.first)
      DeviceLock.synchronize("esp32") do
        key = DeviceLock.env_key("esp32")
        run_rake(dir, *tasks, env: @device_env.call.merge(key => ENV[key]).merge(env), bundle: bundle, limit: limit)
      end
    end

    # Runs rake in dir with the output teed to a numbered log; stops the process group after limit seconds. Returns [success, output, 0].
    #: (String dir, *String tasks, ?env: Hash[String, String?], ?bundle: bool, ?limit: Numeric?) -> [bool, String, Integer]
    def run_rake(dir, *tasks, env: {}, bundle: true, limit: nil)
      @n += 1
      log = File.join(@log_dir, format("%02d-%s.log", @n, tasks.first.tr(":", "_")))
      cmd = bundle ? ["bundle", "exec", "rake", *tasks] : ["rake", *tasks]
      puts "[acceptance] (#{dir}) #{cmd.join(' ')}  -> #{log}"
      out = +""
      stopped = false
      ok = Bundler.with_unbundled_env do
        opts = { chdir: dir, err: [:child, :out] }
        opts[:pgroup] = true if limit
        IO.popen(env, cmd, **opts) do |io|
          watcher = limit && Thread.new do
            Kernel.sleep(limit)
            stopped = true
            Process.kill("TERM", -io.pid)
          rescue Errno::ESRCH
            nil
          end
          File.open(log, "w") do |f|
            io.each_line { |l| print l; f.write(l); out << l }
            if stopped
              line = "[acceptance] stopped after #{limit} s\n"
              print line
              f.write(line)
              out << line
            end
          end
          watcher&.kill
          watcher&.join
        end
        $?.success? && !stopped
      end
      [ok, out, 0]
    end

    # Runs the stackchan CLI of the checkout at root. Returns [success, output, seconds, exit status].
    #: (String root, *String args, ?env: Hash[String, String], ?stdin: String?) -> [bool, String, Float, Integer]
    def cli(root, *args, env: {}, stdin: nil)
      cli = File.join(root, "pc", "stackchan-pico", "bin", "stackchan")
      t0 = now
      out, status = Bundler.with_unbundled_env { Open3.capture2e(env, cli, *args, stdin_data: stdin.to_s) }
      t = now - t0
      envs = env.map { |k, v| "#{k}=#{v} " }.join
      puts "[acceptance] #{envs}stackchan #{args.join(' ')} -> rc=#{status.exitstatus} #{format('%.3f', t)}s"
      [status.success?, out.force_encoding(Encoding::UTF_8), t, status.exitstatus]
    end

    # Returns the monotonic clock in seconds.
    #: () -> Float
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Sleeps for seconds.
    #: (Numeric seconds) -> Integer
    def sleep(seconds) = Kernel.sleep(seconds)
    # Prints an instruction for the operator.
    #: (String text) -> void
    def notice(text) = puts("[acceptance] >>> #{text}")
    # Returns whether stdin is a terminal.
    #: () -> bool
    def tty? = $stdin.tty?

    # Asks the operator a y/n question; returns "y" or "n", or nil without a terminal.
    #: (String question) -> String?
    def prompt(question)
      return nil unless $stdin.tty?
      loop do
        print "[acceptance] #{question} [y/n] "
        a = $stdin.gets.to_s.strip.downcase
        return a if %w[y n].include?(a)
      end
    end
  end
end
