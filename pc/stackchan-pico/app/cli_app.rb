# StackChan CLI, PicoRuby port of pc/stackchan/lib/stackchan/cli.rb.
# Talks to the daemon over picoruby-drb TCP loopback (the CRuby original used a
# Unix-socket DRb; picoruby-drb is TCP/WS only).
#
# Scope (sub-project #3): device-control verbs. chat (AI) waits on the CRuby
# sidecar bridge (#4); tui / demo / calibrate are ported later. The CRuby CLI's
# auto-spawn of the daemon is deferred — here the daemon is started separately;
# a verb against an unreachable daemon reports "not connected".
module Stackchan
  class CLI
    VERBS = %w[status stop say chat face led servo torque selftest raw touch].freeze
    OBSERVE_ONLY = %w[status].freeze

    def self.run(argv, host: "127.0.0.1", port: 8787)
      verb, *args = argv
      unless verb && VERBS.include?(verb)
        usage
        return 1
      end
      DRb.start_service
      daemon = DRb::DRbObject.new_with_uri("druby://#{host}:#{port}")
      # Force a round-trip so an unreachable daemon fails here, not mid-verb.
      begin
        daemon.status
      rescue StandardError => e
        if OBSERVE_ONLY.include?(verb)
          out "stackchan: not connected (#{e.class})"
          return 0
        end
        out "stackchan: daemon unreachable at #{host}:#{port} (#{e.class}: #{e.message})"
        return 1
      end
      new(daemon).dispatch(verb, args)
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
      when "status"   then out @daemon.status.inspect
      when "stop"     then @daemon.stop; out "daemon stopped"
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
      out @daemon.say(text, gain)
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
