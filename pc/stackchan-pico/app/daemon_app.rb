# StackChan PC-side daemon. PicoRuby has no Mutex/Queue/Thread, only
# cooperative Tasks: the drb accept loop and keepalive are Tasks, BLE exclusion
# is a spin on @ble_busy (no yield between test and set), touch events are an
# Array. Voice and AI live in the CRuby sidecar over dRuby; this owns BLE only.

module Stackchan

  # Verb-friendly wrapper over a BLE client's #send (SendBuilder → ACK → detail).
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

    # Played when sidecar.respond returns nil; synthesized once at #start.
    FALLBACK_CHAT_PHRASE = "ちょっと考え中みたい"

    # Half-duplex audio: the device sleeps n*1000/8000 + 3000 ms after <A:N>;
    # wait READY_WAIT_S before blasting, then n/8000 + 2 s after.
    READY_WAIT_S = 1.5

    # Write Without Response has no flow control and the port has no can-send
    # signal; an unpaced blast is silently truncated. 180 bytes / 20 ms = 9 KB/s
    # stays inside the device's receive window.
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
      @fallback_audio = nil
    end

    def start
      @ble.connect
      start_touch_reader
      DRb.start_service("druby://#{@host}:#{@port}", self)
      @server_task    = DRb.thread
      @keepalive_task = start_keepalive
      @running        = true
      # This rescue does not cover a sidecar TCP connect that hangs instead of
      # failing fast: DRb.start_service already ran above and no other Task runs
      # while this one blocks, so that case freezes the whole daemon VM.
      # Known, not fixed here.
      @fallback_audio = begin
        sidecar.synthesize(FALLBACK_CHAT_PHRASE)
      rescue StandardError => e
        log "fallback priming failed: #{e.class}: #{e.message}"
        nil
      end
      log "listening on druby://#{@host}:#{@port}"
      self
    end

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

    # opts Hash, not kwargs: picoruby-drb collapses kwargs into a positional Hash.
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

    def say(text, gain = nil, rate = nil)
      log "[checkpoint] synth_start"
      ulaw = sidecar.synthesize(text, gain, rate)
      log "[checkpoint] synth_done bytes=#{ulaw ? ulaw.bytesize : 0}"
      subtitle = Stackchan::AI::FrameText.build(face_index: nil, text: text)
      with_ble do
        @ble.write_without_ack(subtitle)
        log "[checkpoint] subtitle_write_done"
        stream_audio(ulaw) if ulaw
      end
      record(:say, last_say: text)
      return "NG say: synthesis failed or timed out" unless ulaw
      "OK say bytes=#{ulaw.bytesize}"
    end

    # opts: { speak: true/false, touch_zone: N }
    def chat(text, opts = {})
      opts ||= {}
      speak = opts.key?(:speak) ? opts[:speak] : true
      reply = sidecar.respond(text, chat_context(opts[:touch_zone]))
      record(:chat, last_heard: text)
      if reply
        with_ble { @ble.raw_send(Stackchan::AI::FrameText.build(face_index: 1, text: reply)) }
        say(reply) if speak
      elsif speak && @fallback_audio
        with_ble { stream_audio(@fallback_audio) }
      end
      reply
    end

    def raw_send(frame)
      payload = frame.end_with?("\n") ? frame : "#{frame}\n"
      with_ble { @ble.raw_send(payload) }
      "OK raw"
    end

    # Median of N <read:pos> reads; raises on "unknown".
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

    # Polled by the CLI: picoruby-drb cannot relay a block.
    def poll_touch
      @touch_events.shift   # Array-as-queue; shift/push straddle no yield point
    end

    private

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

    def stream_audio(ulaw)
      n = ulaw.bytesize
      @ble.write_without_ack("<A:#{n}>\n")
      log "[checkpoint] announce_done n=#{n}"
      sleep READY_WAIT_S
      chunk = ble_chunk_size
      i = 0
      chunk_count = 0
      while i < n
        @ble.write_without_ack(ulaw.byteslice(i, chunk))
        i += chunk
        chunk_count += 1
        log "[checkpoint] blast_progress i=#{i} n=#{n}" if chunk_count % 100 == 0
        sleep CHUNK_PACE_S
      end
      log "[checkpoint] blast_done i=#{i} n=#{n}, entering await"
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

    # Cooperative exclusion: no yield between the spin exit and the assignment.
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

    # Idempotent <read:pos> to defeat the Mac's ~15-20 s idle disconnect.
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
