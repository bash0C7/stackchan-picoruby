module StackChan
  class Controller
    # Runs the controller: serves the action table over dRuby, ticks the link, and dispatches touch, periodic and reply handlers.
    class Daemon
      TICK_MS = 250
      TOUCH_ZONE_NAMES = { 0 => :back, 1 => :right, 2 => :left }
      FALLBACK_CHAT_PHRASE = "ちょっと考え中みたい"
      SHUTDOWN_WAIT_MS = 1000
      LISTEN_CAP = 16
      CONNECTED_LINE = "Connected; dRuby pair bound"
      # @rbs @link: Link
      # @rbs @ble: Controller::_Central
      # @rbs @port: Integer
      # @rbs @host: String
      # @rbs @clock: ^() -> Integer
      # @rbs @log_fn: ^(String) -> void
      # @rbs @session: Session
      # @rbs @token: Task::Queue
      # @rbs @touch_handlers: Array[^(Session, Symbol?) -> void]
      # @rbs @reply_handlers: Array[^(Session, String) -> void]
      # @rbs @every: Array[{ ms: Integer, blk: ^(Session) -> void, last_at: Integer? }]
      # @rbs @listen: Array[touch]
      # @rbs @acting: Integer
      # @rbs @actions: Hash[Symbol, Controller::action_entry]
      # @rbs @server_task: Task?
      # @rbs @tick_task: Task?
      # @rbs @shutdown_task: Task?

      # @rbs!
      #   type touch = { zone: Integer, name: Symbol? }
      #   type touch_event = touch | { released: true }
      #   type daemon_status = { link: String, connects: Integer, releases: Integer, last_connect_ms: Integer?, hold_ms: Integer?, ble_connected: bool, last_face: String?, last_action: String?, host: String, port: Integer }

      attr_reader :session #: Session
      attr_reader :reply_handlers #: Array[^(Session, String) -> void]

      # Builds a daemon over the link and central; voice defaults to the dRuby sidecar at sidecar_uri when that is set.
      #: (link: Link, central: Controller::_Central, ?voice: Session::_Voice?, ?port: Integer, ?host: String, ?sidecar_uri: String?, ?clock: ^() -> Integer, ?log: (^(String) -> void)?, ?actions: Hash[Symbol, Controller::action_entry]) -> void
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

      # Registers a handler called with the session and the zone name on every head touch. Returns self.
      #: () { (Session, Symbol?) -> void } -> self
      def on_touch(&blk)
        @touch_handlers << blk
        self
      end

      # Registers a handler called with the session and the reply of every chat. Returns self.
      #: () { (Session, String) -> void } -> self
      def on_reply(&blk)
        @reply_handlers << blk
        self
      end

      # Registers a block run with the session every ms while the link is held. Returns self.
      #: (Integer ms) { (Session) -> void } -> self
      def every(ms, &blk)
        @every << { ms: ms, blk: blk, last_at: nil }
        self
      end

      # Hands the token back while the block runs (for slow work such as synthesis) and returns the block result.
      # Raises LinkChanged when the link was replaced or released meanwhile.
      #: [T] () { () -> T } -> T
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

      # Connects the link (logging Busy), starts the dRuby service and the tick task, and primes the fallback audio. Returns self.
      #: () -> self
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

      # Blocks until the dRuby server task ends and returns it.
      #: () -> Task
      def join
        @server_task.join
      end

      # Stops the tick task and schedules a shutdown task that disconnects BLE and stops the dRuby service. Returns true.
      #: () -> bool
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

      # Returns the link status merged with ble_connected, last_face, last_action, host and port.
      #: () -> daemon_status
      def status
        @link.status.merge(
          ble_connected: @ble.connected?,
          last_face:     @session.state[:last_face],
          last_action:   @session.state[:last_action],
          host:          @host,
          port:          @port,
        )
      end

      # Returns the action table as [name, label] pairs.
      #: () -> Array[[Symbol, String?]]
      def actions
        Controller.listing(@actions)
      end

      # Runs a built-in or declared action by name and returns { status:, out:, message: } where status is :ok, :busy, :unknown or :error.
      #: (String | Symbol name, ?Controller::action_arg arg) -> Controller::result
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

      # Runs one tick: expires or keeps alive the link, dispatches queued touches and runs due periodic blocks.
      #: () -> void
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

      # Calls msg on the robot's dRuby front and returns { status:, out:, message: } with the reply lines in out.
      #: (String | Symbol msg, ?Array[untyped] args) -> Controller::result
      def remote(msg, args = [])
        { status: :ok, out: with_link { @session.remote(msg, *args) }, message: nil }
      rescue Busy => e
        { status: :busy, out: nil, message: e.message }
      rescue StandardError => e
        log "remote #{msg} #{e.class}: #{e.message}"
        { status: :error, out: nil, message: e.message }
      end

      # Returns the oldest queued touch event, { released: true } when the link is not held, or nil.
      #: () -> touch_event?
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

      # Executes a built-in action or the declared block for key and returns its output.
      #: (Symbol key, Controller::action_arg arg) -> untyped
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

      # Runs a calibrate step (begin, sample N or end). Raises ArgumentError for any other step.
      #: (Args args) -> (String | Calibration::pose)
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

      # Reads the position n times and returns the median yaw_raw and pitch_raw.
      #: (Integer n) -> Calibration::pose
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

      # Returns the mu-law bytes of a speak_audio argument: the first element of an Array, or the decoded hex String.
      # Raises ArgumentError for a non-hex String.
      #: (Controller::action_arg arg) -> String
      def audio_bytes(arg)
        return arg[0].to_s if arg.is_a?(Array)
        data = arg.to_s
        raise ArgumentError, "speak_audio: a String argument must be hex" unless hex?(data)
        [data].pack("H*")
      end

      # Returns true when s is a non-empty even-length hex string.
      #: (String s) -> bool
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

      # Takes the token and runs the block inside Link#act, then dispatches touches. Returns the block result.
      #: [T] () { () -> T } -> T
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

      # Moves queued link touches into the listen queue and calls the touch handlers when no action is running.
      #: () -> void
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

      # Runs each periodic block that is due while the link is held; resets the timers otherwise.
      #: () -> void
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

      # Runs the block as a handler: counts it as acting and logs failures.
      #: (String what) { () -> void } -> void
      def handler(what)
        @acting += 1
        begin
          guarded(what) { yield }
        ensure
          @acting -= 1
        end
      end

      # Yields and logs failures; a ConnectionError, or a TimeoutError on a lost link, releases the link.
      #: (String what) { () -> void } -> void
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

      # Starts the task that calls tick every TICK_MS and returns it.
      #: () -> Task
      def start_tick
        daemon = self
        Task.new(name: "tick") do
          while true
            sleep_ms TICK_MS
            daemon.tick
          end
        end
      end

      # Writes msg to the log function.
      #: (String msg) -> void
      def log(msg)
        @log_fn.call(msg)
      end
    end
  end
end
