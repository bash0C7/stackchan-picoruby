# StackChan CLI. Talks to the daemon over picoruby-drb TCP loopback
# (picoruby-drb is TCP/WS only). The daemon is a launchd job started by
# `rake pc:up`; a verb against an unreachable daemon reports
# NOT_RUNNING_MESSAGE, which names that command.
module Stackchan
  class CLI
    VERBS = %w[connect status stop say chat face led servo torque selftest raw touch demo tui calibrate].freeze
    OBSERVE_ONLY = %w[status].freeze

    def self.run(argv, host: "127.0.0.1", port: 8787)
      verb, *args = argv
      unless verb && VERBS.include?(verb)
        usage
        return 1
      end
      DRb.start_service
      daemon = attach(host, port)
      if daemon.nil?
        out NOT_RUNNING_MESSAGE
        return OBSERVE_ONLY.include?(verb) ? 0 : 1
      end
      new(daemon).dispatch(verb, args)
    end

    NOT_RUNNING_MESSAGE =
      "stackchan: backends are not running. Start them with:\n" \
      "  bundle exec rake pc:up"

    def self.attach(host, port, drb_factory: nil, warn_fn: nil)
      factory = drb_factory || lambda { |uri| DRb::DRbObject.new_with_uri(uri) }
      d = factory.call("druby://#{host}:#{port}")
      d.status   # force a real round-trip
      d
    rescue StandardError => e
      # Broad on purpose: a stopped daemon raises SocketError, not DRbConnError.
      warn_fn ? warn_fn.call(e) : $stderr.write("stackchan: attach failed: #{e.class}: #{e.message}\n")
      nil
    end

    def self.usage
      out "Usage: stackchan <verb> [args]"
      out "Verbs: #{VERBS.join(', ')}"
    end

    def self.out(s)
      $stdout.write(s + "\n")
      $stdout.flush
    end

    def initialize(daemon)
      @daemon = daemon
    end

    def dispatch(verb, args)
      case verb
      when "connect"  then out "connected."; out @daemon.status.inspect
      when "status"   then out @daemon.status.inspect
      when "stop"     then @daemon.stop; out "daemon stopped"
      when "demo"     then verb_demo(args)
      when "tui"      then verb_tui
      when "calibrate" then return verb_calibrate(args)
      when "say"      then verb_say(args)
      when "chat"     then verb_chat(args)
      when "face"     then out @daemon.face(args[0])
      when "led"      then verb_led(args)
      when "servo"    then verb_servo(args)
      when "torque"   then out @daemon.torque(args[0] == "on")
      when "selftest" then out @daemon.selftest
      when "raw"      then out @daemon.raw_send(args.join(" "))
      when "touch"    then verb_touch(args)
      else
        self.class.usage
        return 1
      end
      0
    end

    private

    def out(s)
      self.class.out(s)
    end

    def verb_say(args)
      text = args[0]
      opts = parse_kw(args)
      gain = opts["gain"] && opts["gain"].to_f
      rate = opts["rate"] && opts["rate"].to_i
      out @daemon.say(text, gain, rate)
    end

    def verb_chat(args)
      no_speak = false
      idx = args.index("--no-speak")
      if idx
        args.delete_at(idx)
        no_speak = true
      end
      text = args[0]
      reply = @daemon.chat(text, { speak: !no_speak })
      out(reply ? "reply=#{reply}" : "reply=(none)")
    end

    def verb_led(args)
      side, color, mode = args[0], args[1], args[2]
      unless side && color && mode
        out "led: side color mode required"
        return
      end
      out @daemon.led(side: side.to_sym, color: color.to_sym, mode: mode.to_sym)
    end

    def verb_servo(args)
      opts = parse_kw(args)
      detail = @daemon.servo(
        yaw_left:  opts["yaw-left"]  && opts["yaw-left"].to_i,
        yaw_right: opts["yaw-right"] && opts["yaw-right"].to_i,
        pitch_up:  opts["pitch-up"]  && opts["pitch-up"].to_i,
        time_ms:   opts["time"]      && opts["time"].to_i,
        velocity:  opts["velocity"]  && opts["velocity"].to_i,
      )
      out "servo detail=#{detail.inspect}"
    end

    def verb_touch(args)
      sub = args.shift
      unless sub == "listen"
        out "touch <listen>"
        return
      end
      out "[touch] listening (Ctrl-C to exit)..."
      # Poll the daemon (no remote block — picoruby-drb can't relay a Proc).
      loop do
        event = @daemon.poll_touch
        if event
          zone = event[:zone]
          label = @daemon.touch_zone_label(zone)
          out "touch zone=#{zone} (#{label})"
        else
          sleep 0.2
        end
      end
    end

    # Step count, not a Time deadline (no Time on PicoRuby).
    DEMO_SPEECH_RATE = 250   # wpm — faster speech => fewer bytes => less BLE timing exposure
    DEMO_INTRO_LINE = "ぼくスタックチャン！"
    DEMO_OUTRO_LINE = "タッチしてみて"
    DEMO_FACES = %w[joy smile surprised joy smile]
    DEMO_LR_COLORS = [[:red,:blue],[:yellow,:magenta],[:green,:cyan],[:cyan,:red],[:magenta,:yellow],[:white,:green]]
    DEMO_LR_MODES  = [[:blink,:breathing],[:breathing,:solid],[:solid,:blink]]
    DEMO_POSES = [
      { yaw_left: 60, pitch_up: 30, time_ms: 800 },
      { yaw_right: 60, pitch_up: 30, time_ms: 800 },
      { yaw_left: 0, pitch_up: 60, time_ms: 800 },
      { yaw_right: 60, pitch_up: 0, time_ms: 800 },
      { yaw_left: 60, pitch_up: 0, time_ms: 800 },
    ]
    DEMO_STEP_S = 1.2

    def verb_demo(args)
      opts = parse_kw(args)
      duration = (opts["duration"] && opts["duration"].to_f) || 10.0
      steps = (duration / DEMO_STEP_S).to_i
      out "[demo] start"
      @daemon.led({ side: :left,  color: :red,  mode: :blink })
      @daemon.led({ side: :right, color: :blue, mode: :breathing })
      sleep 1.5
      @daemon.say(DEMO_INTRO_LINE, nil, DEMO_SPEECH_RATE)
      sleep 0.5
      i = 0
      while i < steps
        @daemon.face(DEMO_FACES[i % DEMO_FACES.size])
        lc, rc = DEMO_LR_COLORS[i % DEMO_LR_COLORS.size]
        lm, rm = DEMO_LR_MODES[i % DEMO_LR_MODES.size]
        @daemon.led({ side: :left,  color: lc, mode: lm })
        @daemon.led({ side: :right, color: rc, mode: rm })
        @daemon.servo(DEMO_POSES[i % DEMO_POSES.size])
        sleep DEMO_STEP_S
        i += 1
      end
      @daemon.face("neutral")
      @daemon.led({ side: :both, color: :off, mode: :off })
      @daemon.servo({ yaw_left: 0, pitch_up: 0, time_ms: 800 })
      sleep 0.7
      @daemon.say(DEMO_OUTRO_LINE, nil, DEMO_SPEECH_RATE)
      out "[demo] done"
    end

    TUI_HELP = "commands: yl N / yr N / pu N / fwd / ton / toff / face NAME / t MS / h / q"

    def verb_tui
      out TUI_HELP
      move_ms = 800
      loop do
        $stdout.write("\nstackchan> "); $stdout.flush
        line = gets
        break if line.nil?
        parts = line.strip.split(" ")
        cmd = parts[0]
        arg = parts[1]
        next if cmd.nil? || cmd == ""
        case cmd
        when "yl"   then tui_move({ yaw_left: arg.to_i, time_ms: move_ms })
        when "yr"   then tui_move({ yaw_right: arg.to_i, time_ms: move_ms })
        when "pu"   then tui_move({ pitch_up: arg.to_i, time_ms: move_ms })
        when "fwd"  then tui_move({ yaw_left: 0, pitch_up: 0, time_ms: move_ms })
        when "ton"  then out @daemon.torque(true)
        when "toff" then out @daemon.torque(false)
        when "face" then (arg ? out(@daemon.face(arg)) : out("  face requires a name"))
        when "t"    then move_ms = arg.to_i; out "  move duration = #{move_ms} ms"
        when "h", "help" then out TUI_HELP
        when "q", "quit", "exit" then break
        else out "  unknown: #{cmd} (h for help)"
        end
      end
    end

    def tui_move(pose)
      detail = @daemon.servo(pose)
      out "  detail: #{detail.inspect}" if detail
    end

    # Exit codes: 0 ok, 6 device-unknown, 7 verify-fail.
    def verb_calibrate(args)
      align_only = delete_flag(args, "--align-only")
      engage     = delete_flag(args, "--engage-torque")
      no_toggle  = delete_flag(args, "--no-torque-toggle")
      opts = parse_kw(args)
      samples = (opts["samples"] && opts["samples"].to_i) || 3
      fmt = (opts["format"] || "ruby").to_sym
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

    def calibrate_align(skip_torque)
      unless skip_torque
        out "[1/3] <torque:off>..."; @daemon.torque(false); out "  ACK"
      end
      prompt_enter("[2/3] Align FORWARD (LCD facing operator), press Enter (Ctrl-C aborts)...")
      unless skip_torque
        out "[3/3] <torque:on>..."; @daemon.torque(true); out "  ACK"
      end
      out "[done] Ready for operation."
      0
    end

    def calibrate_full(samples, fmt, engage, skip_torque)
      unless skip_torque
        out "[1/6] <torque:off>..."; @daemon.torque(false); out "  ACK"
      end
      poses = {}
      begin
        CalibrationMath::POSE_PROMPTS.each do |pair|
          prompt_enter(pair[1])
          p = @daemon.sample_pose(samples)
          poses[pair[0]] = p
          out "  reading yaw_raw=#{p[:yaw_raw]} pitch_raw=#{p[:pitch_raw]}"
        end
      rescue => e
        out "[FAIL] #{e.message} (device returned unknown — manual calibration needed)"
        return 6
      end
      anchors = CalibrationMath.compute_anchors(poses)
      outcome = CalibrationMath.classify_verify(anchors[:forward_verify])
      if engage && !skip_torque
        @daemon.torque(true); out "[engage] <torque:on> sent."
      end
      out ""
      out CalibrationMath.format(anchors, fmt)
      case outcome
      when :pass then 0
      when :warn then out "[WARN] verify delta exceeded #{CalibrationMath::PASS_TOLERANCE}; review before paste."; 0
      when :fail then out "[FAIL] verify delta exceeded #{CalibrationMath::FAIL_TOLERANCE}; incomplete."; 7
      end
    end

    def prompt_enter(msg)
      $stdout.write(msg + " ")
      $stdout.flush
      gets
    end

    def delete_flag(args, flag)
      idx = args.index(flag)
      return false unless idx
      args.delete_at(idx)
      true
    end

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
