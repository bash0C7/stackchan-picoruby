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
        yaw:      opts[:yaw],
        pitch:    opts[:pitch],
        time_ms:  opts[:time_ms],
        velocity: opts[:velocity],
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
        yaw:      nil,
        pitch:    nil,
        time_ms:  nil,
        velocity: nil,
        socket:   ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:    false,
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-servo [--yaw N] [--pitch N] [--time N] [--velocity N] [--socket PATH] [--quiet]"
        o.on("--yaw N",      Integer) { |v| result[:yaw]      = v }
        o.on("--pitch N",    Integer) { |v| result[:pitch]    = v }
        o.on("--time N",     Integer) { |v| result[:time_ms]  = v }
        o.on("--velocity N", Integer) { |v| result[:velocity] = v }
        o.on("--socket PATH")         { |v| result[:socket]   = v }
        o.on("--quiet")               {     result[:quiet]    = true }
        o.on("-h", "--help") { @stdout.puts(o); exit CliBase::EXIT_OK }
      end
      parser.parse!(argv.dup)
      if result[:yaw].nil? && result[:pitch].nil?
        raise ArgumentError, "at least one of --yaw or --pitch required"
      end
      result
    end
  end
end
