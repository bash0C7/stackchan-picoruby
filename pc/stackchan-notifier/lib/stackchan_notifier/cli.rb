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
    # Values are packed HSB (0xHHSSBB) matching the wire format used by
    # the BLE NUS combo frame protocol. H = 255 * degrees / 360; S and B
    # are 0..255 mapped to 0..1. Achromatic colors (white/gray/black) use
    # S=0 with B set to the desired brightness.
    PRESETS = {
      red:    0x00FFFF,   # H=0°
      green:  0x55FFFF,   # H=120°
      blue:   0xAAFFFF,   # H=240°
      yellow: 0x2AFFFF,   # H=60°
      white:  0x0000FF,   # S=0, B=full
      gray:   0x000080,   # S=0, B=half
      black:  0x000000,   # B=0
    }.freeze
    DEFAULT_LED = [0x000000, :solid].freeze   # unspecified side = visually off

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
      tuple = [
        :notify,
        opts[:face],
        opts[:left][0],  opts[:left][1],
        opts[:right][0], opts[:right][1],
        opts[:duration],
      ]
      try_send(opts[:socket], tuple, quiet: opts[:quiet])
      EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-notify: #{e.message}"
      EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        face:     nil,
        left:     DEFAULT_LED,
        right:    DEFAULT_LED,
        duration: nil,
        socket:   ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:    false,
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-notify --face NAME [--left_led COLOR,MODE] [--right_led COLOR,MODE] [--duration N] [--socket PATH] [--quiet]"
        o.on("--face NAME",            "one of: #{FACES.join(' / ')}")                              { |v| result[:face] = v.to_sym }
        o.on("--left_led COLOR,MODE",  "LED for StackChan's left hand (default: 0x000000,solid = off).",
                                       "COLOR = preset name (#{PRESETS.keys.join(' / ')}) or packed HSB hex 0xHHSSBB.",
                                       "MODE  = #{MODES.join(' / ')}.")                            { |v| result[:left]  = parse_led(v) }
        o.on("--right_led COLOR,MODE", "LED for StackChan's right hand (default: 0x000000,solid = off).",
                                       "COLOR = preset name (#{PRESETS.keys.join(' / ')}) or packed HSB hex 0xHHSSBB.",
                                       "MODE  = #{MODES.join(' / ')}.")                            { |v| result[:right] = parse_led(v) }
        o.on("--duration N", Integer,  "auto-restore to neutral + both LEDs off after N seconds")  { |v| result[:duration] = v }
        o.on("--socket PATH",          "DRb Unix socket (env: STACKCHAN_NOTIFIER_SOCKET,",
                                       "default: #{StackchanNotifier.default_socket_path})")       { |v| result[:socket] = v }
        o.on("--quiet",                "suppress 'daemon unavailable' stderr (CLI still exits 0)") { result[:quiet] = true }
        o.on("-h", "--help",           "show this help and exit")                                  { @stdout.puts(o); print_extras; exit EXIT_OK }
      end
      parser.parse!(argv.dup)

      raise ArgumentError, "--face required (one of #{FACES.join(' / ')})" unless FACES.include?(result[:face])
      if result[:duration] && result[:duration] <= 0
        raise ArgumentError, "--duration must be a positive integer (got #{result[:duration]})"
      end
      result
    end

    def parse_led(spec)
      color_str, mode_str = spec.split(",", 2)
      raise ArgumentError, "--left_led / --right_led must be COLOR,MODE (got #{spec.inspect})" if color_str.nil? || mode_str.nil? || color_str.empty? || mode_str.empty?
      [parse_color(color_str), parse_mode(mode_str)]
    end

    def parse_color(str)
      return PRESETS[str.to_sym] if PRESETS.key?(str.to_sym)
      begin
        val = Integer(str, 16)
      rescue ArgumentError
        raise ArgumentError, "color must be a preset name (#{PRESETS.keys.join(' / ')}) or packed HSB hex 0xHHSSBB (0x000000..0xFFFFFF); got #{str.inspect}"
      end
      raise ArgumentError, "color out of range (0x000000..0xFFFFFF): #{str}" if val < 0 || val > 0xFFFFFF
      val
    end

    def parse_mode(str)
      sym = str.to_sym
      raise ArgumentError, "mode must be one of #{MODES.join(' / ')}; got #{str.inspect}" unless MODES.include?(sym)
      sym
    end

    def print_extras
      @stdout.puts
      @stdout.puts "Color presets:"
      PRESETS.each { |name, hex| @stdout.puts format("  %-7s = 0x%06X", name, hex) }
    end

    def try_send(socket, tuple, quiet:)
      @sender.call(socket, tuple)
    rescue DRb::DRbConnError, Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES => e
      return if quiet
      @stderr.puts "stackchan-notify: daemon unavailable (#{e.class}: #{e.message})"
    end
  end
end
