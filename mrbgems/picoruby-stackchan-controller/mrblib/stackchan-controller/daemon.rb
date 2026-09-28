module StackChan
  class Controller
    class Daemon
      TICK_MS = 250
      TOUCH_ZONE_NAMES = { 0 => :back, 1 => :right, 2 => :left }
      FALLBACK_CHAT_PHRASE = "ちょっと考え中みたい"
      SHUTDOWN_WAIT_MS = 1000

      attr_reader :session, :reply_handlers

      def initialize(link:, central:, voice: nil, port: 8787, host: "127.0.0.1", sidecar_uri: "druby://127.0.0.1:8788",
                     clock: -> { Machine.board_millis }, log: nil)
        @link           = link
        @ble            = central
        @port           = port
        @host           = host
        @clock          = clock
        @log_fn         = log || ->(line) { $stderr.write("[stackchand] #{line}\n"); $stderr.flush }
        voice         ||= DRb::DRbObject.new_with_uri(sidecar_uri) if sidecar_uri
        @session        = Session.new(central: central, engine: self, voice: voice, log: @log_fn)
        @token          = Task::Queue.new
        @token.push(true)
        @touch_handlers = []
        @reply_handlers = []
        @every          = []
        @listen         = []
        @dispatching    = false
        start_touch_reader
      end

      def on_touch(&blk)
        @touch_handlers << blk
        self
      end

      def on_reply(&blk)
        @reply_handlers << blk
        self
      end

      def every(ms, &blk)
        @every << { ms: ms, blk: blk, last_at: nil }
        self
      end

      def unlocked
        @token.push(true)
        begin
          yield
        ensure
          @token.pop
        end
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
        begin
          @session.prime(FALLBACK_CHAT_PHRASE)
        rescue StandardError => e
          log "fallback priming failed: #{e.class}: #{e.message}"
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
          last_face:     @session.state[:last_face],
          last_action:   @session.state[:last_action],
        }.merge(@link.status)
      end

      def tick
        @token.pop
        begin
          begin
            @link.tick
          rescue StandardError => e
            log "tick #{e.class}: #{e.message}"
          end
          dispatch_touches
          run_every
        ensure
          @token.push(true)
        end
      end

      def face(name)
        with_link { @session.face(name) }
        "OK face=#{name}"
      end

      def led(opts)
        with_link { @session.led(opts[:side], opts[:color], mode: opts[:mode]) }
        "OK led=#{opts[:side]}/#{opts[:color]}/#{opts[:mode]}"
      end

      def servo(opts)
        with_link do
          @session.servo(yaw_left: opts[:yaw_left], yaw_right: opts[:yaw_right], pitch_up: opts[:pitch_up],
                         time_ms: opts[:time_ms], velocity: opts[:velocity])
        end
      end

      def torque(on)
        with_link { @session.torque(on) }
        "OK torque=#{on ? 'on' : 'off'}"
      end

      def selftest
        with_link { @session.selftest }
        "OK selftest"
      end

      def say(text, gain = nil, rate = nil)
        with_link { @session.say(text, gain: gain, rate: rate) }
      end

      def chat(text, opts)
        with_link { @session.chat(text, speak: opts[:speak]) }
      end

      def raw_send(frame)
        payload = frame.end_with?("\n") ? frame : "#{frame}\n"
        with_link { @ble.raw_send(payload) }
        "OK raw"
      end

      def remote(msg, args = [])
        with_link { @session.remote(msg, *args) }
      end

      def sample_pose(n)
        readings = []
        i = 0
        while i < n
          readings << with_link { @session.read_pos }
          i += 1
        end
        {
          yaw_raw:   Calibration.median(readings.map { |r| r[:yaw_raw] }),
          pitch_raw: Calibration.median(readings.map { |r| r[:pitch_raw] }),
        }
      end

      def poll_touch
        @token.pop
        begin
          held = @link.state == :held
          @link.listening! if held
          event = @listen.shift
          return event if event
          held ? nil : { released: true }
        ensure
          @token.push(true)
        end
      end

      private

      def with_link
        @token.pop
        begin
          @link.act { yield }
        ensure
          dispatch_touches
          @token.push(true)
        end
      end

      def dispatch_touches
        return if @dispatching
        @dispatching = true
        begin
          while (zone = @link.touches.shift)
            name = TOUCH_ZONE_NAMES[zone]
            @listen << { zone: zone, name: name }
            @touch_handlers.each do |h|
              guarded("on_touch") { h.call(@session, name) }
            end
          end
        ensure
          @dispatching = false
        end
      end

      def run_every
        now = @clock.call
        @every.each do |e|
          unless @link.state == :held
            e[:last_at] = nil
            next
          end
          if e[:last_at].nil?
            e[:last_at] = now
          elsif now - e[:last_at] >= e[:ms]
            e[:last_at] = now
            guarded("every") { e[:blk].call(@session) }
          end
        end
      end

      def guarded(what)
        yield
      rescue ConnectionError => e
        log "#{what} #{e.class}: #{e.message}"
        @link.lost!
      rescue TimeoutError => e
        log "#{what} #{e.class}: #{e.message}"
        @link.lost! if @ble.lost?
      rescue StandardError => e
        log "#{what} #{e.class}: #{e.message}"
      end

      def start_touch_reader
        @ble.on_unsolicited = lambda do |frame|
          zone = Stackchan::BLE::FrameCodec.parse_touch(frame)
          next unless zone
          @link.touches.push(zone)
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
