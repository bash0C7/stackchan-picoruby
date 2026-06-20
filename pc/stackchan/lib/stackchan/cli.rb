# frozen_string_literal: true

require "drb/drb"
require "drb/unix"
require_relative "daemon"

module Stackchan
  class CLI
    VERBS = %w[connect status stop say chat face led servo torque selftest calibrate touch tui raw demo].freeze

    # status is a passive observer — never auto-spawns the daemon.
    # Every other verb implicitly establishes the link if missing.
    OBSERVE_ONLY_VERBS = %w[status].freeze

    def self.run(argv)
      verb, *args = argv
      return usage if verb.nil? || !VERBS.include?(verb)
      daemon = attach_or_spawn(spawn_if_missing: !OBSERVE_ONLY_VERBS.include?(verb))
      if daemon.nil?
        puts "stackchan: not connected. use 'stackchan connect' to establish the link."
        return 0
      end
      new(daemon).dispatch(verb, args)
    end

    def self.usage
      warn "Usage: stackchan <verb> [args]"
      warn "Verbs: #{VERBS.join(', ')}"
      1
    end

    def self.attach_or_spawn(uri: "drbunix:#{Daemon::DEFAULT_SOCKET_PATH}", spawn_if_missing: true, timeout_s: 15.0)
      DRb.start_service unless DRb.primary_server
      deadline = Time.now + timeout_s
      spawned = false
      loop do
        begin
          daemon = DRbObject.new_with_uri(uri)
          daemon.status  # force a real round-trip so DRbConnError surfaces here
          return daemon
        rescue DRb::DRbConnError
          return nil unless spawn_if_missing
          unless spawned
            spawn_daemon
            spawned = true
          end
          raise "daemon failed to come up within #{timeout_s}s" if Time.now > deadline
          sleep 0.3
        end
      end
    end

    def self.spawn_daemon
      daemon_exe = File.expand_path("../../exe/stackchand", __dir__)
      log_path = "/tmp/stackchand-#{Process.uid}.log"
      pid = Process.spawn(daemon_exe, [:out, :err] => log_path)
      Process.detach(pid)
    end

    def initialize(daemon)
      @daemon = daemon
    end

    def dispatch(verb, args)
      case verb
      when "connect" then verb_connect
      when "status"  then verb_status
      when "stop"    then verb_stop
      when "say"     then verb_say(args)
      when "chat"    then verb_chat(args)
      when "face"    then @daemon.face(args[0])
      when "led"     then verb_led(args)
      when "servo"   then verb_servo(args)
      when "torque"  then verb_torque(args)
      when "selftest" then @daemon.selftest
      when "touch"   then verb_touch(args)
      when "raw"     then @daemon.raw_send(args.join(" "))
      when "calibrate" then return verb_calibrate(args)
      when "tui"     then verb_tui
      when "demo"    then verb_demo(args)
      else return self.class.usage
      end
      0
    end

    private

    def verb_say(args)
      text = args.shift
      opts = parse_kw(args)
      gain = opts["gain"]&.to_f
      @daemon.say(text, voice: opts["voice"], gain: gain)
    end

    def verb_chat(args)
      no_speak_idx = args.index("--no-speak")
      args.delete_at(no_speak_idx) if no_speak_idx
      speak = no_speak_idx.nil?
      text = args.shift
      reply = @daemon.chat(text, speak: speak)
      puts reply if reply
    end

    def verb_led(args)
      side, color, mode = args[0], args[1], args[2]
      raise ArgumentError, "led: side / color / mode required" unless side && color && mode
      @daemon.led(side: side.to_sym, color: color.to_sym, mode: mode.to_sym)
    end

    def verb_servo(args)
      opts = parse_kw(args)
      @daemon.servo(
        yaw_left:  opts["yaw-left"]&.to_i,
        yaw_right: opts["yaw-right"]&.to_i,
        pitch_up:  opts["pitch-up"]&.to_i,
        time_ms:   opts["time"]&.to_i,
        velocity:  opts["velocity"]&.to_i,
      )
    end

    def verb_torque(args)
      on = args[0] == "on"
      @daemon.torque(on)
    end

    def verb_touch(args)
      sub = args.shift
      return usage_error("touch <listen>") unless sub == "listen"
      react = args.delete("--react")
      @daemon.subscribe_touch do |event|
        puts event.inspect
        zone = event[:zone]
        # Immediate visible feedback BEFORE any AI / chat work, so the human
        # sees the robot acknowledge the touch within a frame round-trip
        # (~50ms) instead of waiting ~2-5s for the FM reply to come back.
        @daemon.face(@daemon.touch_zone_face(zone))
        next unless react
        label = @daemon.touch_zone_label(zone)
        prompt = label ? "#{label}を触られた" : "頭の zone=#{zone} を触られた"
        @daemon.chat(prompt, touch_zone: zone)
      end
    end

    def verb_connect
      puts "connected."
      puts @daemon.status.inspect
    end

    def verb_status
      puts @daemon.status.inspect
    end

    def verb_stop
      @daemon.stop
      puts "daemon stopped"
    rescue DRb::DRbConnError
      # daemon already tearing down its DRb service — that's fine, expected.
      puts "daemon stopped"
    end

    def verb_calibrate(args)
      require_relative "calibrate"
      align_only = !!args.delete("--align-only")
      engage_torque = !!args.delete("--engage-torque")
      no_torque_toggle = !!args.delete("--no-torque-toggle")
      opts = parse_kw(args)
      samples = opts["samples"]&.to_i || 3
      format = (opts["format"] || "ruby").to_sym
      Stackchan::Calibrate::Runner.new(@daemon).run(
        align_only: align_only,
        samples: samples,
        format: format,
        engage_torque: engage_torque,
        no_torque_toggle: no_torque_toggle,
      )
    end

    def verb_tui
      require_relative "tui"
      Stackchan::TUI::Runner.new(@daemon).run
    end

    def verb_demo(args)
      require_relative "demo"
      opts = parse_kw(args)
      duration = opts["duration"]&.to_f || Stackchan::Demo::DEFAULT_DURATION_S
      no_listen = args.include?("--no-listen")
      Stackchan::Demo::Runner.new(@daemon).run(duration: duration)
      return if no_listen
      puts "[demo] listening for touch (Ctrl-C to exit)..."
      @daemon.subscribe_touch do |event|
        puts event.inspect
        zone = event[:zone]
        @daemon.face(@daemon.touch_zone_face(zone))
        label = @daemon.touch_zone_label(zone)
        prompt = label ? "#{label}を触られた" : "頭の zone=#{zone} を触られた"
        @daemon.chat(prompt, touch_zone: zone)
      end
    end

    def parse_kw(args)
      out = {}
      i = 0
      while i < args.length
        a = args[i]
        if a&.start_with?("--")
          out[a[2..]] = args[i + 1]
          i += 2
        else
          i += 1
        end
      end
      out
    end

    def usage_error(msg)
      warn "stackchan: #{msg}"
      1
    end
  end
end
