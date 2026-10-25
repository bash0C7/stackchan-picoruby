module StackChan
  class Controller
    # Command-line front end: sends each verb to the running daemon over dRuby and prints the result.
    class CLI
      BUILTIN_VERBS = %w[connect status stop raw calibrate remote touch tui]
      TOUCH_POLL_MS = 200
      TUI_HELP = "commands: <verb> [args] (one action per line) / h / q"
      # @rbs @daemon: _Daemon
      # @rbs @clock: ^() -> Integer

      # @rbs!
      #   interface _Daemon
      #     def status: () -> Daemon::daemon_status
      #     def act: (String | Symbol name, ?Controller::action_arg arg) -> Controller::result
      #     def actions: () -> Array[[Symbol, String?]]
      #     def remote: (String | Symbol msg, ?Array[untyped] args) -> Controller::result
      #     def poll_touch: () -> Daemon::touch_event?
      #   end

      # Attaches to the daemon at host:port, dispatches argv and returns the exit status.
      # Prints a start hint and returns 1 (0 for status) when no daemon is running.
      #: (Array[String] argv, ?host: String, ?port: Integer) -> Integer
      def self.run(argv, host: "127.0.0.1", port: 8787)
        verb, *args = argv
        DRb.start_service
        daemon = attach(host, port)
        if daemon.nil?
          out NOT_RUNNING_MESSAGE
          return verb == "status" ? 0 : 1
        end
        cli = new(daemon)
        return cli.usage if verb.nil?
        cli.dispatch(verb, args)
      end

      NOT_RUNNING_MESSAGE =
        "stackchan: backends are not running. Start them with:\n" \
        "  bundle exec rake pc:up"

      # Returns the daemon proxy at host:port after a status call, or nil (reporting through warn_fn) when it cannot be reached.
      #: (String host, Integer port, ?drb_factory: (^(String) -> _Daemon)?, ?warn_fn: (^(StandardError) -> void)?) -> _Daemon?
      def self.attach(host, port, drb_factory: nil, warn_fn: nil)
        factory = drb_factory || lambda { |uri| DRb::DRbObject.new_with_uri(uri) }
        d = factory.call("druby://#{host}:#{port}")
        d.status
        d
      rescue StandardError => e
        warn_fn ? warn_fn.call(e) : $stderr.write("stackchan: attach failed: #{e.class}: #{e.message}\n")
        nil
      end

      # Writes s and a newline to stdout and flushes.
      #: (String s) -> void
      def self.out(s)
        $stdout.write(s + "\n")
        $stdout.flush
      end

      # Builds a CLI over the daemon proxy.
      #: (_Daemon daemon, ?clock: ^() -> Integer) -> void
      def initialize(daemon, clock: -> { Machine.board_millis })
        @daemon = daemon
        @clock  = clock
      end

      # Runs one verb with its arguments and returns the exit status.
      #: (String verb, Array[String] args) -> Integer
      def dispatch(verb, args)
        case verb
        when "calibrate" then verb_calibrate(args)
        when "remote"    then verb_remote(args)
        when "touch"     then verb_touch(args)
        when "tui"       then verb_tui
        else                  report(@daemon.act(verb, args))
        end
      end

      # Prints the usage and the verb list and returns 1.
      #: () -> Integer
      def usage
        names = BUILTIN_VERBS.dup
        @daemon.actions.each do |pair|
          name = pair[0].to_s
          names << name unless names.include?(name)
        end
        out "Usage: stackchan <verb> [args]"
        out "Verbs: #{names.join(', ')}"
        1
      end

      private

      # Instance shortcut for CLI.out.
      #: (String s) -> void
      def out(s)
        self.class.out(s)
      end

      # Prints an act result and returns the exit status: 0 ok, 8 busy, 1 otherwise (the usage for an unknown action).
      #: (Controller::result result) -> Integer
      def report(result)
        case result[:status]
        when :ok
          print_out(result[:out])
          0
        when :busy
          out "busy: #{result[:message]}"
          8
        when :unknown
          usage
        else
          out "error: #{result[:message]}"
          1
        end
      end

      # Prints an Array one line per element, a Hash as key=value pairs, and any other non-nil value with to_s.
      #: (untyped value) -> void
      def print_out(value)
        if value.is_a?(Array)
          value.each { |line| out line.to_s.chomp }
        elsif value.is_a?(Hash)
          out value.map { |k, v| "#{k}=#{v}" }.join(" ")
        elsif !value.nil?
          out value.to_s
        end
      end

      # Runs the remote verb: calls a method of the robot's front with KEY=VALUE pairs as one Hash or with plain arguments. Returns 1 when the first reply line is ?.
      #: (Array[String] args) -> Integer
      def verb_remote(args)
        msg = args.shift
        unless msg
          out "remote <command|face|servo|led|text|torque|read_pos> [KEY=VALUE ... | ARG ...]"
          return 0
        end
        call_args = args
        if !args.empty? && args.all? { |a| a.include?("=") }
          frame = {}
          args.each do |a|
            k, v = a.split("=", 2)
            frame[k] = v
          end
          call_args = [frame]
        end
        result = @daemon.remote(msg, call_args)
        code = report(result)
        return code unless code == 0
        first = result[:out].is_a?(Array) ? result[:out][0] : nil
        first == "?" || first == "?\n" ? 1 : 0
      end

      # Runs touch listen: prints touch zones until --count events, --timeout seconds or a released link. Returns 0 when the count is reached, 1 otherwise.
      #: (Array[String] args) -> Integer
      def verb_touch(args)
        sub = args.shift
        unless sub == "listen"
          out "touch <listen>"
          return 0
        end
        opts = parse_kw(args)
        count = opts["count"] && opts["count"].to_i
        timeout_ms = opts["timeout"] && (opts["timeout"].to_f * 1000).to_i
        connected = @daemon.act(:connect, [])
        return report(connected) unless connected[:status] == :ok
        out "[touch] listening (Ctrl-C to exit)..."
        seen = 0
        started = @clock.call
        while true
          event = @daemon.poll_touch
          if event && event[:zone]
            out "touch zone=#{event[:zone]} (#{event[:name]})"
            seen += 1
            return 0 if count && seen >= count
          elsif event && event[:released]
            out "[touch] released"
            return 1
          elsif timeout_ms && @clock.call - started >= timeout_ms
            out "[touch] timed out"
            return 1
          else
            sleep_ms TOUCH_POLL_MS
          end
        end
      end

      # Runs the interactive prompt, one action per line, until q. Returns 0.
      #: () -> Integer
      def verb_tui
        out TUI_HELP
        while (line = read_line("\nstackchan> "))
          words = line.strip.split(" ")
          verb = words.shift
          next if verb.nil?
          case verb
          when "q", "quit", "exit" then break
          when "h", "help"         then usage
          else                          report(@daemon.act(verb, words))
          end
        end
        0
      end

      # Prints the prompt and returns the next stdin line, or nil at end of input.
      #: (String prompt) -> String?
      def read_line(prompt)
        $stdout.write(prompt)
        $stdout.flush
        gets
      end

      # Runs the calibrate verb (--align-only, --engage-torque, --no-torque-toggle, --samples, --format). Returns 0, 1, 6 (calibration needed), 7 (verify failed or interrupted).
      #: (Array[String] args) -> Integer
      def verb_calibrate(args)
        align_only = delete_flag(args, "--align-only")
        engage     = delete_flag(args, "--engage-torque")
        no_toggle  = delete_flag(args, "--no-torque-toggle")
        opts = parse_kw(args)
        samples = (opts["samples"] && opts["samples"].to_i) || 3
        fmt = (opts["format"] || "ruby").to_sym
        unless Calibration::FORMATS.include?(fmt)
          out "calibrate: --format ruby|env|json"
          return 1
        end
        if align_only
          calibrate_align(no_toggle)
        else
          calibrate_full(samples, fmt, engage, no_toggle)
        end
      rescue Interrupt
        $stderr.write("[INTERRUPT] operator aborted calibration; torque remains off.\n")
        $stderr.flush
        7
      end

      # Runs the alignment-only calibration: torque off, wait for the operator, torque on. Returns the exit status.
      #: (bool skip_torque) -> Integer
      def calibrate_align(skip_torque)
        unless skip_torque
          out "[1/3] <torque:off>..."
          _, code = calibrate_step(["begin"])
          return code if code
          out "  ACK"
        end
        prompt_enter("[2/3] Align FORWARD (LCD facing operator), press Enter (Ctrl-C aborts)...")
        unless skip_torque
          out "[3/3] <torque:on>..."
          _, code = calibrate_step(["end"])
          return code if code
          out "  ACK"
        end
        out "[done] Ready for operation."
        0
      end

      # Runs the full calibration: samples every pose, prints the anchors and returns 0 (pass or warn) or 7 (fail).
      #: (Integer samples, Symbol fmt, bool engage, bool skip_torque) -> Integer
      def calibrate_full(samples, fmt, engage, skip_torque)
        unless skip_torque
          out "[1/6] <torque:off>..."
          _, code = calibrate_step(["begin"])
          return code if code
          out "  ACK"
        end
        poses = {}
        i = 0
        while i < Calibration::POSE_PROMPTS.size
          pair = Calibration::POSE_PROMPTS[i]
          prompt_enter(pair[1])
          reading, code = calibrate_step(["sample", samples.to_s])
          return code if code
          poses[pair[0]] = reading
          out "  reading yaw_raw=#{reading[:yaw_raw]} pitch_raw=#{reading[:pitch_raw]}"
          i += 1
        end
        anchors = Calibration.compute_anchors(poses)
        outcome = Calibration.classify_verify(anchors[:forward_verify])
        if engage && !skip_torque
          _, code = calibrate_step(["end"])
          return code if code
          out "[engage] <torque:on> sent."
        end
        out ""
        out Calibration.format(anchors, fmt)
        case outcome
        when :pass then 0
        when :warn then out "[WARN] verify delta exceeded #{Calibration::PASS_TOLERANCE}; review before paste."; 0
        when :fail then out "[FAIL] verify delta exceeded #{Calibration::FAIL_TOLERANCE}; incomplete."; 7
        end
      end

      # Runs one calibrate step on the daemon and returns [output, nil] on success or [nil, exit status] on failure.
      #: (Array[String] words) -> [(String | Calibration::pose)?, Integer?]
      def calibrate_step(words)
        result = @daemon.act(:calibrate, words)
        return [result[:out], nil] if result[:status] == :ok
        return [nil, report(result)] if result[:status] == :busy
        message = result[:message].to_s
        if message.include?(Calibration::UNKNOWN_POSITION)
          out "[FAIL] #{message} (manual calibration needed)"
          return [nil, 6]
        end
        out "[FAIL] #{message}"
        [nil, 1]
      end

      # Prints msg and waits for the operator to press Enter.
      #: (String msg) -> void
      def prompt_enter(msg)
        $stdout.write(msg + " ")
        $stdout.flush
        gets
      end

      # Removes flag from args and returns whether it was present.
      #: (Array[String] args, String flag) -> bool
      def delete_flag(args, flag)
        idx = args.index(flag)
        return false unless idx
        args.delete_at(idx)
        true
      end

      # Parses --key value pairs from args into a Hash keyed by the name without dashes.
      #: (Array[String] args) -> Hash[String, String?]
      def parse_kw(args)
        out = {}
        i = 0
        while i < args.length
          a = args[i]
          if a && a[0, 2] == "--"
            out[a[2, a.length - 2]] = args[i + 1]
            i += 2
          else
            i += 1
          end
        end
        out
      end
    end
  end
end
