require "optparse"
require "drb/drb"
require "drb/unix"

require_relative "../stackchan_notifier"

module StackchanNotifier
  # Thin client invoked by Claude Code hooks. Reads args, writes one tuple to
  # the daemon's TupleSpace over DRb, exits. Never touches BLE directly.
  #
  # Exit codes:
  #   0 = success, OR daemon unavailable (intentional: hooks must never block
  #       Claude Code on missing infrastructure)
  #   2 = invalid CLI arguments (visible misconfiguration)
  class CLI
    FACES = %i[neutral smile joy surprised].freeze
    MODES = %i[solid blink breathing off].freeze
    SIDES = %i[left right both].freeze

    EXIT_OK      = 0
    EXIT_BAD_ARG = 2

    def self.run(argv, stdout: $stdout, stderr: $stderr, sender: method(:drb_send))
      new(stdout: stdout, stderr: stderr, sender: sender).run(argv)
    end

    def self.drb_send(socket, tuple)
      DRb.start_service
      DRbObject.new_with_uri("drbunix:#{socket}").write(tuple)
    end

    def initialize(stdout:, stderr:, sender:)
      @stdout = stdout
      @stderr = stderr
      @sender = sender
    end

    def run(argv)
      opts = parse(argv)
      tuple = [:notify, opts[:face], opts[:hsb], opts[:mode], opts[:side]]
      try_send(opts[:socket], tuple, quiet: opts[:quiet])
      EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-notify: #{e.message}"
      EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        face:   nil,
        hsb:    nil,
        mode:   nil,
        side:   :both,
        socket: ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:  false,
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-notify --face NAME --hsb HEX --mode NAME [--side NAME] [--socket PATH] [--quiet]"
        o.on("--face NAME",   "one of: #{FACES.join(' / ')}")                                  { |v| result[:face] = v.to_sym }
        o.on("--hsb HEX",     "color hex, e.g. 0x55FF80 (range 0x000000..0xFFFFFF)")           { |v| result[:hsb]  = parse_hex(v) }
        o.on("--mode NAME",   "one of: #{MODES.join(' / ')}")                                  { |v| result[:mode] = v.to_sym }
        o.on("--side NAME",   "one of: #{SIDES.join(' / ')} (default: both)")                  { |v| result[:side] = v.to_sym }
        o.on("--socket PATH", "DRb Unix socket (env: STACKCHAN_NOTIFIER_SOCKET,",
                              "default: #{StackchanNotifier.default_socket_path})")            { |v| result[:socket] = v }
        o.on("--quiet",       "suppress 'daemon unavailable' stderr (CLI still exits 0)")      { result[:quiet] = true }
        o.on("-h", "--help",  "show this help and exit")                                       { @stdout.puts(o); exit EXIT_OK }
      end
      parser.parse!(argv.dup)

      raise ArgumentError, "--face required (one of #{FACES.join(' / ')})" unless FACES.include?(result[:face])
      raise ArgumentError, "--hsb required (e.g. 0x55FF80)"                 if result[:hsb].nil?
      raise ArgumentError, "--mode required (one of #{MODES.join(' / ')})" unless MODES.include?(result[:mode])
      raise ArgumentError, "--side must be one of #{SIDES.join(' / ')}"    unless SIDES.include?(result[:side])
      raise ArgumentError, "--hsb out of range (0x000000..0xFFFFFF)"        if result[:hsb] < 0 || result[:hsb] > 0xFFFFFF

      result
    end

    def parse_hex(str)
      Integer(str, 16)
    rescue ArgumentError, TypeError
      raise ArgumentError, "--hsb must be a hex value like 0x55FF80 (got #{str.inspect})"
    end

    def try_send(socket, tuple, quiet:)
      @sender.call(socket, tuple)
    rescue DRb::DRbConnError, Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES => e
      return if quiet
      @stderr.puts "stackchan-notify: daemon unavailable (#{e.class}: #{e.message})"
    end
  end
end
