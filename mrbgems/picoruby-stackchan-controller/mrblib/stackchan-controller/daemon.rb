module StackChan
  class Controller
    class Daemon
      TICK_MS = 250
      TOUCH_ZONE_NAMES = { 0 => :back, 1 => :right, 2 => :left }
      FALLBACK_CHAT_PHRASE = "ちょっと考え中みたい"
      SHUTDOWN_WAIT_MS = 1000
      LISTEN_CAP = 16
      CONNECTED_LINE = "Connected; RX value_handle bound"

      attr_reader :session, :reply_handlers

      def initialize(link:, central:, voice: nil, port: 8787, host: "127.0.0.1", sidecar_uri: "druby://127.0.0.1:8788",
                     clock: -> { Machine.board_millis }, log: nil, actions: {})
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
        @acting         = 0
        @actions        = actions
        @link.on_lost   = -> { @listen.clear }
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
        generation = @link.generation
        @token.push(true)
        begin
          result = yield
        ensure
          @token.pop
        end
        if @link.generation != generation || @link.state == :released
          raise LinkChanged, "link changed while the token was handed back"
        end
        result
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
        ble = @ble
        @shutdown_task = Task.new(name: "shutdown") do
          sleep_ms SHUTDOWN_WAIT_MS
          ble.disconnect
          DRb.stop_service
        end
        true
      end

      def status
        @link.status.merge(
          ble_connected: @ble.connected?,
          last_face:     @session.state[:last_face],
          last_action:   @session.state[:last_action],
          host:          @host,
          port:          @port,
        )
      end

      def actions
        Controller.listing(@actions)
      end

      def act(name, arg = nil)
        key = name.to_s.to_sym
        unless BUILTINS.include?(key) || @actions.key?(key)
          return { status: :unknown, out: nil, message: "unknown action: #{key}" }
        end
        begin
          { status: :ok, out: perform(key, arg), message: nil }
        rescue Busy => e
          { status: :busy, out: nil, message: e.message }
        rescue StandardError => e
          log "act #{key} #{e.class}: #{e.message}"
          { status: :error, out: nil, message: e.message }
        end
      end

      def tick
        @token.pop
        begin
          begin
            @link.tick(expire: @acting == 0)
          rescue StandardError => e
            log "tick #{e.class}: #{e.message}"
          end
          dispatch_touches
          run_every
        ensure
          @token.push(true)
        end
      end

      def remote(msg, args = [])
        { status: :ok, out: with_link { @session.remote(msg, *args) }, message: nil }
      rescue Busy => e
        { status: :busy, out: nil, message: e.message }
      rescue StandardError => e
        log "remote #{msg} #{e.class}: #{e.message}"
        { status: :error, out: nil, message: e.message }
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

      def perform(key, arg)
        case key
        when :connect
          with_link {}
          CONNECTED_LINE
        when :status
          status
        when :stop
          stop
          "daemon stopped"
        when :raw
          frame = arg.is_a?(String) ? arg : Args.new(arg).words.join(" ")
          payload = frame.end_with?("\n") ? frame : "#{frame}\n"
          with_link { @ble.raw_send(payload) }
          "OK raw"
        when :calibrate
          calibrate(Args.new(arg))
        when :speak_audio
          ulaw = audio_bytes(arg)
          with_link { @session.speak_audio(ulaw) }
          "OK speak_audio bytes=#{ulaw.bytesize}"
        else
          blk = @actions[key][:blk]
          args = Args.new(arg, flags: @actions[key][:flags])
          with_link { blk.call(@session, args) }
        end
      end

      def calibrate(args)
        case args[0]
        when "begin"
          with_link { @session.torque(false) }
          "OK calibrate begin"
        when "sample"
          sample_pose((args[1] || "3").to_i)
        when "end"
          with_link { @session.torque(true) }
          "OK calibrate end"
        else
          raise ArgumentError, "calibrate: begin | sample N | end"
        end
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

      def audio_bytes(arg)
        return arg[0].to_s if arg.is_a?(Array)
        data = arg.to_s
        raise ArgumentError, "speak_audio: a String argument must be hex" unless hex?(data)
        [data].pack("H*")
      end

      def hex?(s)
        return false if s.empty? || s.bytesize.odd?
        i = 0
        while i < s.bytesize
          b = s.getbyte(i)
          return false unless (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
          i += 1
        end
        true
      end

      def with_link
        @token.pop
        @acting += 1
        begin
          @link.act { yield }
        ensure
          begin
            @acting -= 1
            dispatch_touches
          ensure
            @token.push(true)
          end
        end
      end

      def dispatch_touches
        return unless @acting == 0
        while (zone = @link.touches.shift)
          name = TOUCH_ZONE_NAMES[zone]
          @listen << { zone: zone, name: name }
          @listen.shift while @listen.size > LISTEN_CAP
          @touch_handlers.each do |h|
            handler("on_touch") { h.call(@session, name) }
          end
        end
      end

      def run_every
        return unless @acting == 0
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
            handler("every") { e[:blk].call(@session) }
          end
        end
      end

      def handler(what)
        @acting += 1
        begin
          guarded(what) { yield }
        ensure
          @acting -= 1
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

      def start_tick
        daemon = self
        Task.new(name: "tick") do
          while true
            sleep_ms TICK_MS
            daemon.tick
          end
        end
      end

      def log(msg)
        @log_fn.call(msg)
      end
    end
  end
end
