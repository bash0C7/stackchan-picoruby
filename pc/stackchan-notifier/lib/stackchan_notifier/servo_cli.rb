require "optparse"

require_relative "../stackchan_notifier"
require_relative "cli_base"

module StackchanNotifier
  class ServoCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr, sender: CliBase.method(:drb_send))
      new(stdout: stdout, stderr: stderr, sender: sender).run(argv)
    end

    def initialize(stdout:, stderr:, sender:)
      @stdout = stdout
      @stderr = stderr
      @sender = sender
    end

    def run(argv)
      opts = parse(argv)
      tuple = [:cmd, :servo, {
        yaw_left:  opts[:yaw_left],
        yaw_right: opts[:yaw_right],
        pitch_up:  opts[:pitch_up],
        time_ms:   opts[:time_ms],
        velocity:  opts[:velocity],
      }]
      CliBase.try_send(
        sender: @sender, socket: opts[:socket], tuple: tuple,
        stderr: @stderr, quiet: opts[:quiet], program_name: "stackchan-servo",
      )
      CliBase::EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-servo: #{e.message}"
      CliBase::EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        yaw_left:  nil,
        yaw_right: nil,
        pitch_up:  nil,
        time_ms:   nil,
        velocity:  nil,
        socket:    ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:     false,
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-servo [--yaw-left N] [--yaw-right N] [--pitch-up N] [--time N] [--velocity N] [--socket PATH] [--quiet]"
        o.on("--yaw-left N",  Integer) { |v| result[:yaw_left]  = v }
        o.on("--yaw-right N", Integer) { |v| result[:yaw_right] = v }
        o.on("--pitch-up N",  Integer) { |v| result[:pitch_up]  = v }
        o.on("--time N",      Integer) { |v| result[:time_ms]   = v }
        o.on("--velocity N",  Integer) { |v| result[:velocity]  = v }
        o.on("--socket PATH")          { |v| result[:socket]    = v }
        o.on("--quiet")                {     result[:quiet]     = true }
        o.on("-h", "--help") { @stdout.puts(o); exit CliBase::EXIT_OK }
      end
      parser.parse!(argv.dup)
      if result[:yaw_left].nil? && result[:yaw_right].nil? && result[:pitch_up].nil?
        raise ArgumentError, "at least one of --yaw-left, --yaw-right, or --pitch-up required"
      end
      if !result[:yaw_left].nil? && !result[:yaw_right].nil?
        raise ArgumentError, "--yaw-left and --yaw-right are mutually exclusive"
      end
      result
    end
  end
end
