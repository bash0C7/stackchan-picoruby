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

    # Phase1 half-duplex audio protocol (port of Stackchan::Voice::Streamer).
    # Device sleeps T = n*1000/8000 + 3000ms starting right after <A:N>, so the
    # PC must wait READY_WAIT_S before blasting (lets the device heartbeat pick
    # up the announce) and then n/8000 + 2.0s after the blast (play + margin)
    # before sending anything else over the link.
    READY_WAIT_S = 1.5

    # Write Without Response has no flow control at the ATT layer, and the
    # darwin BLE port exposes no can-send-now signal, so an unpaced blast
    # outruns the radio and CoreBluetooth silently discards the overflow.
    # Measured: every clip, whatever its length, reached the device as exactly
    # 11340 bytes (63 chunks of 180) and played truncated. The device's own
    # receive window is n*1000/8000 + 3000ms, so the blast has to stay at or
    # above ~8KB/s to fit inside it; 180 bytes per 20ms is 9KB/s, the fastest
    # pace that still leaves the window room to spare.
    CHUNK_PACE_S = 0.02

    def initialize(ble:, port: 8787, host: "127.0.0.1", sidecar_uri: "druby://127.0.0.1:8788")
      @ble           = ble
      @port          = port
      @host          = host
      @sidecar_uri   = sidecar_uri
      @sidecar       = nil
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

    # say: TTS runs in the CRuby sidecar (say/afconvert -> mu-law); the daemon
    # gets the bytes over dRuby, pushes the on-LCD subtitle, then streams the
    # audio over BLE. The sidecar call (network, no BLE) stays OUTSIDE with_ble.
    def say(text, gain = nil, rate = nil)
      ulaw = sidecar.synthesize(text, gain, rate)
      subtitle = Stackchan::AI::FrameText.build(face_index: nil, text: text)
      with_ble do
        @ble.write_without_ack(subtitle)
        stream_audio(ulaw) if ulaw
      end
      record(:say, last_say: text)
      "OK say bytes=#{ulaw ? ulaw.bytesize : 0}"
    end

    # chat: AI reply text comes from the sidecar (FM); the daemon frames it to
    # the LCD and optionally speaks it. opts Hash (drb cannot carry kwargs):
    # { speak: true/false, touch_zone: N }.
    def chat(text, opts = {})
      opts ||= {}
      speak = opts.key?(:speak) ? opts[:speak] : true
      reply = sidecar.respond(text, chat_context(opts[:touch_zone]))
      record(:chat, last_heard: text)
      if reply
        with_ble { @ble.raw_send(Stackchan::AI::FrameText.build(face_index: 1, text: reply)) }
        say(reply) if speak
      end
      reply
    end

    def raw_send(frame)
      payload = frame.end_with?("\n") ? frame : "#{frame}\n"
      with_ble { @ble.raw_send(payload) }
      "OK raw"
    end

    # Sample the servo raw position N times (median) for calibration. Each
    # <read:pos> returns a <yaw_raw:N,pitch_raw:M> detail frame. Raises if the
    # device reports "unknown" (operator manual calibration needed).
    def sample_pose(samples = 3)
      n = samples || 3
      readings = []
      i = 0
      while i < n
        with_ble { @ble.send { |s| s.read_pos } }
        parsed = CalibrationMath.parse_raw_detail(@ble.last_detail_frame.to_s)
        if parsed[:yaw_raw].nil? || parsed[:pitch_raw].nil?
          raise Stackchan::BLE::DeviceError, "device returned unknown raw position"
        end
        readings << parsed
        i += 1
      end
      {
        yaw_raw:   CalibrationMath.median(readings.map { |r| r[:yaw_raw] }),
        pitch_raw: CalibrationMath.median(readings.map { |r| r[:pitch_raw] }),
      }
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

    # Lazy dRuby client to the CRuby AI/voice sidecar. picoruby-drb opens a
    # fresh socket per call, so a dropped sidecar just fails the next call.
    def sidecar
      @sidecar ||= DRb::DRbObject.new_with_uri(@sidecar_uri)
    end

    def chat_context(touch_zone)
      ctx = {
        last_face:   @robot_state[:last_face],
        last_say:    @robot_state[:last_say],
        last_heard:  @robot_state[:last_heard],
        last_action: @robot_state[:last_action],
      }
      if touch_zone
        ctx[:touch_zone]       = touch_zone
        ctx[:touch_zone_label] = TOUCH_ZONE_LABELS[touch_zone]
      end
      ctx
    end

    # Stream a mu-law clip over BLE using the Phase1 half-duplex protocol
    # (port of Stackchan::Voice::Streamer#stream_halfduplex): announce -> wait
    # for the device to enter receive mode -> blast -> wait for the device's
    # <A:done> completion notification (see StackchanCentral#await_audio_done
    # for why an active wait replaced the original fixed-sleep estimate).
    # Caller already holds the BLE link (invoked inside with_ble).
    def stream_audio(ulaw)
      n = ulaw.bytesize
      @ble.write_without_ack("<A:#{n}>\n")
      sleep READY_WAIT_S
      chunk = ble_chunk_size
      i = 0
      while i < n
        @ble.write_without_ack(ulaw.byteslice(i, chunk))
        i += chunk
        sleep CHUNK_PACE_S
      end
      @ble.await_audio_done(n)
    end

    def ble_chunk_size
      n = (@ble.max_write_chunk rescue nil)
      n && n > 0 ? n : 180
    end

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
