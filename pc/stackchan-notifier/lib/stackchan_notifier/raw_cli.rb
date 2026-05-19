require "optparse"

require_relative "../stackchan_notifier"
require_relative "cli_base"

module StackchanNotifier
  class RawCLI
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
      tuple = [:cmd, :raw, { frame: opts[:frame] }]
      CliBase.try_send(
        sender: @sender, socket: opts[:socket], tuple: tuple,
        stderr: @stderr, quiet: opts[:quiet], program_name: "stackchan-raw",
      )
      CliBase::EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-raw: #{e.message}"
      CliBase::EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        frame:  nil,
        socket: ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:  false,
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-raw --frame STRING [--socket PATH] [--quiet]"
        o.on("--frame STRING") { |v| result[:frame]  = v }
        o.on("--socket PATH")  { |v| result[:socket] = v }
        o.on("--quiet")        {     result[:quiet]  = true }
        o.on("-h", "--help") { @stdout.puts(o); exit CliBase::EXIT_OK }
      end
      parser.parse!(argv.dup)
      raise ArgumentError, "--frame STRING required" if result[:frame].nil?
      raise ArgumentError, "--frame must not be empty" if result[:frame].empty?
      result
    end
  end
end
