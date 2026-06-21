# StackChan PC-side daemon, PicoRuby port of pc/stackchan/lib/stackchan/daemon.rb.
#
# Concurrency model differs from the CRuby original because PicoRuby has no
# Mutex/Queue/Thread — only cooperative Tasks (switch only at yield points:
# sleep / blocking I/O / Task.pass):
#   - drb server accept loop  : DRb.thread (a Task)
#   - keepalive               : a Task issuing idempotent <read:pos>
#   - BLE mutual exclusion     : a cooperative spinlock on @ble_busy (no Mutex);
#                                set/clear straddles no yield point, so it is atomic
#   - touch event channel      : a plain Array drained by subscribe_touch (no Queue)
#
# Voice (say audio) and AI (chat) stay in a CRuby sidecar reached over dRuby
# (sub-project #4); this daemon owns BLE device control only. `say` here emits
# only the on-LCD subtitle frame; `chat` is wired in #4.

module Stackchan
  module BLE
    class Error < StandardError; end
    class TimeoutError < Error; end
    class DeviceError < Error; end
    class ConnectionError < Error; end
  end

  # Thin verb-friendly wrapper over a BLE client's #send (builds frames via the
  # shared SendBuilder, waits ACK, captures the detail frame). Port of
  # pc/stackchan/lib/stackchan/display.rb.
  class Display
    def initialize(ble)
      @ble = ble
    end

    def face(name)
      @ble.send { |s| s.face(name.to_sym) }
    end

    def led(side:, color:, mode:)
      form, value = color.is_a?(Array) ? color : [color, nil]
      @ble.send { |s| s.led(form, value, side: side.to_sym, mode: mode.to_sym) }
    end

    def servo(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
      @ble.send do |s|
        s.head(yaw_left: yaw_left, yaw_right: yaw_right, pitch_up: pitch_up,
               time_ms: time_ms, velocity: velocity)
      end
      @ble.last_detail_frame
    end

    def torque(on)
      @ble.send { |s| s.torque(on: on) }
    end

    def selftest
      @ble.send { |s| s.selftest }
    end
  end

  class Daemon
    KEEPALIVE_INTERVAL_S = 7
    TOUCH_ZONE_LABELS = { 0 => "頭のうしろ", 1 => "右側", 2 => "左側" }

    def initialize(ble:, port: 8787, host: "127.0.0.1")
      @ble           = ble
      @port          = port
      @host          = host
      @display       = Display.new(@ble)
      @robot_state   = { last_face: nil, last_say: nil, last_heard: nil, last_action: nil }
      @touch_events  = []
      @ble_busy      = false
      @running       = false
    end

    def start
      @ble.connect
      start_touch_reader
      DRb.start_service("druby://#{@host}:#{@port}", self)
      @server_task    = DRb.thread
      @keepalive_task = start_keepalive
      @running        = true
      log "listening on druby://#{@host}:#{@port}"
      self
    end

    # Keep the VM alive on the drb accept loop until stop.
    def join
      @server_task.join
    end

    def stop
      @running = false
      @keepalive_task&.terminate
      DRb.stop_service rescue nil
      begin
        @ble.disconnect
      rescue StandardError
        # already gone
      end
      true
    end

    # === Verb-facing API (called by the CLI via the drb proxy) ===

    def status
      {
        ble_connected: @ble.connected?,
        host:          @host,
        port:          @port,
        last_face:     @robot_state[:last_face],
        last_action:   @robot_state[:last_action],
      }
    end

    def face(name)
      with_ble { @display.face(name) }
      record(:face, last_face: name.to_s)
      "OK face=#{name}"
    end

    # opts hash, NOT keyword args: picoruby-drb collapses a caller's keyword
    # syntax into a trailing positional Hash, and mruby does not auto-convert a
    # positional Hash back into required keywords (it raises ArgumentError). So
    # every multi-field drb-facing verb takes a single Hash.
    def led(opts)
      with_ble { @display.led(side: opts[:side], color: opts[:color], mode: opts[:mode]) }
      record(:led)
      "OK led=#{opts[:side]}/#{opts[:color]}/#{opts[:mode]}"
    end

    def servo(opts)
      detail = with_ble do
        @display.servo(yaw_left: opts[:yaw_left], yaw_right: opts[:yaw_right],
                       pitch_up: opts[:pitch_up], time_ms: opts[:time_ms],
                       velocity: opts[:velocity])
      end
      record(:servo)
      detail
    end

    def torque(on)
      with_ble { @display.torque(on) }
      record(:torque)
      "OK torque=#{on ? 'on' : 'off'}"
    end

    def selftest
      with_ble { @display.selftest }
      record(:selftest)
      "OK selftest"
    end

    # say: subtitle-only on the PC PicoRuby side. Voice synthesis lives in the
    # CRuby sidecar (sub-project #4); here we push just the on-LCD subtitle.
    def say(text)
      frame = Stackchan::AI::FrameText.build(face_index: nil, text: text)
      with_ble { @ble.write_without_ack(frame) }
      record(:say, last_say: text)
      "OK say"
    end

    def raw_send(frame)
      payload = frame.end_with?("\n") ? frame : "#{frame}\n"
      with_ble { @ble.raw_send(payload) }
      "OK raw"
    end

    def touch_zone_label(zone)
      TOUCH_ZONE_LABELS[zone]
    end

    # Returns the next buffered touch event Hash (e.g. {type: :touch, zone: 1})
    # or nil if none pending. The CLI polls this in a loop — picoruby-drb cannot
    # relay a remote block (it Marshals the Proc, which fails), so the CRuby
    # `subscribe_touch { |e| ... }` yield-back model is not available. Polling
    # also keeps each drb call short, so the single server task stays free for
    # other verbs between polls.
    def poll_touch
      @touch_events.shift   # Array-as-queue; shift/push straddle no yield point
    end

    private

    def record(action, extras = {})
      @robot_state[:last_action] = action.to_s
      extras.each { |k, v| @robot_state[k] = v }
    end

    # Cooperative BLE exclusion (no Mutex on PicoRuby). Tasks switch only at
    # yield points, so spinning with Task.pass until the flag clears, then
    # setting it, is race-free: there is no yield between the while-test exit
    # and the assignment. Lazy reconnect on a dropped link mirrors the CRuby
    # daemon's with_ble.
    def with_ble
      Task.pass while @ble_busy
      @ble_busy = true
      begin
        yield
      rescue Stackchan::BLE::ConnectionError, Stackchan::BLE::TimeoutError => e
        log "with_ble #{e.class}: #{e.message} — reconnecting"
        reconnect
        yield
      ensure
        @ble_busy = false
      end
    end

    def reconnect
      begin
        @ble.disconnect
      rescue StandardError
      end
      @ble.connect
      start_touch_reader
      log "reconnected"
    end

    def start_touch_reader
      @ble.on_unsolicited = lambda do |frame|
        zone = Stackchan::BLE::FrameCodec.parse_touch(frame)
        next unless zone
        @touch_events.push({ type: :touch, zone: zone })
      end
    end

    # Idempotent <read:pos> on an interval to defeat Mac CoreBluetooth's
    # ~15-20s idle disconnect. Skips if a verb currently holds the BLE link.
    def start_keepalive
      Task.new(name: "keepalive") do
        while @running
          KEEPALIVE_INTERVAL_S.times { sleep 1 }
          break unless @running
          begin
            with_ble { @ble.send { |s| s.read_pos } }
          rescue StandardError => e
            log "keepalive #{e.class}: #{e.message}"
          end
        end
      end
    end

    def log(msg)
      $stderr.write("[stackchand] #{msg}\n")
      $stderr.flush
    end
  end
end
