require "optparse"
require "logger"
require "fileutils"
require "drb/drb"
require "drb/unix"
require "stackchan_ble_client"
require "stackchan_ble_client/frame_codec"

require_relative "../stackchan_notifier"
require_relative "tuple_space4ractor"
require_relative "worker"

module StackchanNotifier
  # Long-running Mac-side process. Owns the TupleSpace4Ractor, exposes it
  # over DRb on a Unix socket, and runs the BLE worker thread that drains
  # tuples and forwards them as combo frames.
  class Daemon
    LEVELS = {
      "debug" => Logger::DEBUG,
      "info"  => Logger::INFO,
      "warn"  => Logger::WARN,
      "error" => Logger::ERROR,
    }.freeze

    def self.run_with_argv(argv, stdout: $stdout, stderr: $stderr)
      opts = parse(argv, stderr: stderr)
      daemon = new(opts: opts)
      daemon.install_signal_handlers
      daemon.start
      daemon.wait
      daemon.shutdown
      0
    rescue OptionParser::ParseError => e
      stderr.puts "stackchan-notifier-daemon: #{e.message}"
      2
    end

    def self.parse(argv, stderr: $stderr)
      result = {
        device_name: ENV["BLE_DEVICE_NAME"] || "StackChan-PicoRuby",
        name_prefix: nil,
        socket:      ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        log_level:   "info",
      }
      OptionParser.new do |o|
        o.banner = "Usage: stackchan-notifier-daemon [--device-name NAME] [--name-prefix PREFIX] [--socket PATH] [--log-level LEVEL]"
        o.on("--device-name NAME") { |v| result[:device_name] = v }
        o.on("--name-prefix PREFIX") { |v| result[:name_prefix] = v }
        o.on("--socket PATH") { |v| result[:socket] = v }
        o.on("--log-level LEVEL") do |v|
          raise OptionParser::InvalidArgument, "--log-level must be one of #{LEVELS.keys.join(' / ')}" unless LEVELS.key?(v)
          result[:log_level] = v
        end
      end.parse!(argv.dup)
      result
    end

    attr_reader :opts, :ts, :worker

    def initialize(opts:, client_factory: nil, logger: nil, ts: nil, ai_touch: nil)
      @opts            = opts
      @logger          = logger || build_logger(opts[:log_level])
      @client_factory  = client_factory || default_client_factory(opts)
      @ts              = ts
      @started         = false
      @stopped         = false
      @stop_mutex      = Mutex.new
      @stop_cv         = ConditionVariable.new
      @ai_touch        = ai_touch.nil? ? (ENV["STACKCHAN_AI_TOUCH"] == "1") : ai_touch
    end

    def start
      raise Error, "daemon already started" if @started
      cleanup_stale_socket
      @ts ||= TupleSpace4Ractor.new
      DRb.start_service(drb_uri, @ts)
      File.chmod(0o600, socket_path) if File.exist?(socket_path)
      @worker = Worker.new(
        ts:                 @ts,
        client_factory:     @client_factory,
        logger:             @logger,
        handlers:           build_handlers,
        on_unsolicited:     (@ai_touch ? build_touch_unsolicited(@ts) : nil),
        keepalive_interval: (@ai_touch ? 10.0 : nil),
      ).start
      @started = true
      @logger.info("stackchan-notifier-daemon: listening on #{drb_uri}")
      self
    end

    # Block the calling thread until #stop is called (e.g. from a signal handler).
    def wait
      @stop_mutex.synchronize { @stop_cv.wait(@stop_mutex) until @stopped }
      self
    end

    # Called from a signal handler — must stay async-signal-safe-ish.
    def stop
      @stop_mutex.synchronize do
        @stopped = true
        @stop_cv.signal
      end
    end

    def shutdown
      return self unless @started
      @logger.info("stackchan-notifier-daemon: shutting down")
      @worker&.shutdown
      begin
        DRb.stop_service
      rescue StandardError => e
        @logger.warn("DRb.stop_service raised #{e.class}: #{e.message}")
      end
      FileUtils.rm_f(socket_path)
      @started = false
      self
    end

    def install_signal_handlers
      # Ruby 4.0+ raises ThreadError if Mutex#synchronize runs inside a
      # signal handler. `stop` and `force_reconnect` both take locks (a
      # plain Mutex, and Rinda's internal lock respectively), so defer
      # the actual work to a fresh thread spawned from the trap. The
      # trap itself does nothing but Thread.new, which is signal-safe.
      %w[INT TERM].each { |sig| Signal.trap(sig) { Thread.new { stop } } }
      Signal.trap("HUP") { Thread.new { @worker&.force_reconnect } }
      self
    end

    def socket_path
      @opts[:socket]
    end

    def drb_uri
      "drbunix:#{socket_path}"
    end

    private

    def build_handlers
      return Worker::DEFAULT_HANDLERS unless @ai_touch
      require "foundation_model_mac"
      require "stackchan_notifier/handlers/touch_reaction_handler"
      session = AppleFoundationModel::Session.new(
        instructions: Handlers::TouchReactionHandler::PERSONA
      )
      Worker::DEFAULT_HANDLERS.merge(
        react_touch: Handlers::TouchReactionHandler.new(session: session)
      )
    end

    def build_touch_unsolicited(ts)
      lambda do |frame|
        zone = StackchanBleClient::FrameCodec.parse_touch(frame)
        ts.write([:cmd, :react_touch, { zone: zone }]) if zone
      end
    end

    def cleanup_stale_socket
      return unless File.exist?(socket_path)
      unless File.socket?(socket_path)
        raise Error, "refusing to remove non-socket file at #{socket_path}"
      end
      FileUtils.rm_f(socket_path)
    end

    def build_logger(level)
      # Force line-buffered output so that `... 2>&1 > daemon.log` shows
      # progress events (BLE connect, reconnect, send failures) the moment
      # they happen, rather than accumulating in a 4KB block buffer that
      # only flushes on shutdown.
      $stdout.sync = true
      logger = Logger.new($stdout)
      logger.level = LEVELS.fetch(level, Logger::INFO)
      logger.formatter = ->(severity, time, _progname, msg) {
        "[#{time.iso8601}] #{severity} #{msg}\n"
      }
      logger
    end

    def default_client_factory(opts)
      -> {
        StackchanBleClient::Client.new(
          device_name: opts[:device_name],
          name_prefix: opts[:name_prefix],
        )
      }
    end
  end
end
