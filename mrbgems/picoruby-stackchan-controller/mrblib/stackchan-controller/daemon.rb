module StackChan
  class Controller
    class Daemon
      TICK_MS = 250
      TOUCH_ZONE_LABELS = { 0 => "頭のうしろ", 1 => "右側", 2 => "左側" }
      FALLBACK_CHAT_PHRASE = "ちょっと考え中みたい"
      READY_WAIT_MS = 1500
      AUDIO_CHUNK = 180
      CHUNK_PACE_MS = 20
      SHUTDOWN_WAIT_MS = 1000

      def initialize(link:, central:, port: 8787, host: "127.0.0.1", sidecar_uri: "druby://127.0.0.1:8788", log: nil)
        @link          = link
        @ble           = central
        @port          = port
        @host          = host
        @sidecar_uri   = sidecar_uri
        @sidecar       = nil
        @log_fn        = log || ->(line) { $stderr.write("[stackchand] #{line}\n"); $stderr.flush }
        @robot_state   = { last_face: nil, last_say: nil, last_heard: nil, last_action: nil }
        @token         = Task::Queue.new
        @token.push(true)
        @fallback_audio = nil
        start_touch_reader
      end

      def start
        begin
          with_link {}
        rescue Busy => e
          log "busy: #{e.message}"
        end
        DRb.start_service("druby://#{@host}:#{@port}", self)
        @server_task    = DRb.thread
        @tick_task      = start_tick
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
        @tick_task.terminate
        Task.new(name: "shutdown") do
          sleep_ms SHUTDOWN_WAIT_MS
          @ble.disconnect
          DRb.stop_service
        end
        true
      end

      def status
        {
          ble_connected: @ble.connected?,
          host:          @host,
          port:          @port,
          last_face:     @robot_state[:last_face],
          last_action:   @robot_state[:last_action],
        }.merge(@link.status)
      end

      def tick
        @token.pop
        begin
          @link.tick
        rescue StandardError => e
          log "tick #{e.class}: #{e.message}"
        ensure
          @token.push(true)
        end
      end

      def face(name)
        with_link { @ble.send { |s| s.face(name.to_sym) } }
        record(:face, last_face: name.to_s)
        "OK face=#{name}"
      end

      def led(opts)
        with_link { @ble.send { |s| s.led(opts[:color], side: opts[:side], mode: opts[:mode]) } }
        record(:led)
        "OK led=#{opts[:side]}/#{opts[:color]}/#{opts[:mode]}"
      end

      def servo(opts)
        detail = with_link do
          @ble.send do |s|
            s.head(yaw_left: opts[:yaw_left], yaw_right: opts[:yaw_right], pitch_up: opts[:pitch_up],
                   time_ms: opts[:time_ms], velocity: opts[:velocity])
          end
          @ble.last_detail_frame
        end
        record(:servo)
        detail
      end

      def torque(on)
        with_link { @ble.send { |s| s.torque(on: on) } }
        record(:torque)
        "OK torque=#{on ? 'on' : 'off'}"
      end

      def selftest
        with_link { @ble.send { |s| s.selftest } }
        record(:selftest)
        "OK selftest"
      end

      def say(text, gain = nil, rate = nil)
        log "[checkpoint] synth_start"
        ulaw = sidecar.synthesize(text, gain, rate)
        log "[checkpoint] synth_done bytes=#{ulaw ? ulaw.bytesize : 0}"
        subtitle = Stackchan::AI::FrameText.build(face_index: nil, text: text)
        with_link do
          @ble.write_without_ack(subtitle)
          log "[checkpoint] subtitle_write_done"
          stream_audio(ulaw) if ulaw
        end
        record(:say, last_say: text)
        return "NG say: synthesis failed or timed out" unless ulaw
        "OK say bytes=#{ulaw.bytesize}"
      end

      def chat(text, opts)
        speak = opts[:speak]
        reply = sidecar.respond(text, @robot_state.dup)
        record(:chat, last_heard: text)
        if reply
          with_link { @ble.raw_send(Stackchan::AI::FrameText.build(face_index: 1, text: reply)) }
          say(reply) if speak
        elsif speak && @fallback_audio
          with_link { stream_audio(@fallback_audio) }
        end
        reply
      end

      def raw_send(frame)
        payload = frame.end_with?("\n") ? frame : "#{frame}\n"
        with_link { @ble.raw_send(payload) }
        "OK raw"
      end

      def remote(msg, args = [])
        lines = with_link { @ble.remote.send(msg.to_sym, *args) }
        record(:remote)
        lines
      end

      def sample_pose(n)
        readings = []
        i = 0
        while i < n
          with_link { @ble.send { |s| s.read_pos } }
          parsed = Calibration.parse_raw_detail(@ble.last_detail_frame.to_s)
          if parsed[:yaw_raw].nil? || parsed[:pitch_raw].nil?
            raise DeviceError, Calibration::UNKNOWN_POSITION
          end
          readings << parsed
          i += 1
        end
        {
          yaw_raw:   Calibration.median(readings.map { |r| r[:yaw_raw] }),
          pitch_raw: Calibration.median(readings.map { |r| r[:pitch_raw] }),
        }
      end

      def poll_touch
        @link.touches.shift
      end

      private

      def sidecar
        @sidecar ||= DRb::DRbObject.new_with_uri(@sidecar_uri)
      end

      def stream_audio(ulaw)
        n = ulaw.bytesize
        @ble.write_without_ack("<A:#{n}>\n")
        log "[checkpoint] announce_done n=#{n}"
        sleep_ms READY_WAIT_MS
        i = 0
        chunk_count = 0
        while i < n
          @ble.write_without_ack(ulaw.byteslice(i, AUDIO_CHUNK))
          i += AUDIO_CHUNK
          chunk_count += 1
          log "[checkpoint] blast_progress i=#{i} n=#{n}" if chunk_count % 100 == 0
          sleep_ms CHUNK_PACE_MS
        end
        log "[checkpoint] blast_done i=#{i} n=#{n}, entering await"
        @ble.await_audio_done(n)
      end

      def record(action, extras = {})
        @robot_state[:last_action] = action.to_s
        extras.each { |k, v| @robot_state[k] = v }
      end

      def with_link
        @token.pop
        begin
          @link.act { yield }
        ensure
          @token.push(true)
        end
      end

      def start_touch_reader
        @ble.on_unsolicited = lambda do |frame|
          zone = Stackchan::BLE::FrameCodec.parse_touch(frame)
          next unless zone
          @link.touches.push({ zone: zone, label: TOUCH_ZONE_LABELS[zone] })
        end
      end

      def start_tick
        Task.new(name: "tick") do
          while true
            sleep_ms TICK_MS
            tick
          end
        end
      end

      def log(msg)
        @log_fn.call(msg)
      end
    end
  end
end
