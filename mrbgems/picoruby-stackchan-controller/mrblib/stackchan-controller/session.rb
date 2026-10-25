module StackChan
  class Controller
    # Operator-facing actions of one controller: face, LED, servo, torque, text, audio, voice and remote calls over the central.
    class Session
      AUDIO_CHUNK         = 2048
      AUDIO_POLL_MS       = 500
      AUDIO_TAIL_MS       = 400
      AUDIO_MARGIN_MS     = 600
      # @rbs @central: Controller::_Central
      # @rbs @engine: _Engine
      # @rbs @voice: _Voice?
      # @rbs @log: ^(String) -> void
      # @rbs @state: state
      # @rbs @fallback_audio: String?

      #
      # @rbs!
      #   type state = { last_face: String?, last_say: String?, last_heard: String?, last_action: String? }
      #   type state_update = { ?last_face: String, ?last_say: String, ?last_heard: String }
      #   interface _Voice
      #     def synthesize: (String text, ?Float? gain, ?Integer? rate) -> String?
      #     def respond: (String text, state state) -> String?
      #   end
      #
      #   interface _Engine
      #     def unlocked: [T] () { () -> T } -> T
      #     def reply_handlers: () -> Array[^(Session, String) -> void]
      #   end

      attr_reader :state #: state
      attr_accessor :fallback_audio #: String?

      # Builds a session over the central and the engine; voice supplies synthesize and respond for say and chat.
      #: (central: Controller::_Central, engine: _Engine, ?voice: _Voice?, log: ^(String) -> void) -> void
      def initialize(central:, engine:, voice: nil, log:)
        @central        = central
        @engine         = engine
        @voice          = voice
        @log            = log
        @state          = { last_face: nil, last_say: nil, last_heard: nil, last_action: nil }
        @fallback_audio = nil
      end

      # Sends the face frame and records the action. Returns nil.
      #: (String | Symbol name) -> nil
      def face(name)
        @central.send { |b| b.face(name.to_sym) }
        record(:face, last_face: name.to_s)
        nil
      end

      # Sends the LED frame for a side and color and records the action. Returns nil.
      #: (Stackchan::BLE::FrameCodec::side side, Symbol color, ?mode: Stackchan::BLE::FrameCodec::led_mode mode) -> nil
      def led(side, color, mode: :solid)
        @central.send { |b| b.led(color, side: side, mode: mode) }
        record(:led)
        nil
      end

      # Sends one head frame and returns the detail frame of the reply (the pose at receive time), or nil.
      #: (?yaw_left: Integer?, ?yaw_right: Integer?, ?pitch_up: Integer?, ?time_ms: Integer?, ?velocity: Integer?) -> String?
      def servo(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
        @central.send do |b|
          b.head(yaw_left: yaw_left, yaw_right: yaw_right, pitch_up: pitch_up, time_ms: time_ms, velocity: velocity)
        end
        record(:servo)
        @central.last_detail_frame
      end

      # Sends the torque on/off frame and records the action. Returns nil.
      #: (bool on) -> nil
      def torque(on)
        @central.send { |b| b.torque(on: on) }
        record(:torque)
        nil
      end

      # Sends the selftest frame and returns the detail frame of the reply, or nil.
      #: () -> String?
      def selftest
        @central.send { |b| b.selftest }
        record(:selftest)
        @central.last_detail_frame
      end

      # Reads the raw yaw and pitch positions. Returns { yaw_raw:, pitch_raw: }; raises DeviceError when the position is unknown.
      #: () -> Hash[Symbol, Integer]
      def read_pos
        @central.send { |b| b.read_pos }
        parsed = Calibration.parse_raw_detail(@central.last_detail_frame.to_s)
        raise DeviceError, Calibration::UNKNOWN_POSITION if parsed[:yaw_raw].nil? || parsed[:pitch_raw].nil?
        parsed
      end

      # Sends a subtitle text frame; face is a face name Symbol, a face index String, or nil. Returns nil.
      #: (String s, ?face: (Symbol | String)?) -> nil
      def text(s, face: nil)
        index = face.is_a?(Symbol) ? Stackchan::BLE::FrameCodec::FACE_INDICES.fetch(face) : face
        @central.raw_send(Stackchan::AI::FrameText.build(face_index: index, text: s))
        nil
      end

      # Streams mu-law audio to the robot in 2048-byte chunks, starts playback and polls until it is done.
      # Raises TimeoutError when playback does not finish within the limit. Returns nil.
      #: (String ulaw) -> nil
      def speak_audio(ulaw)
        n = ulaw.bytesize
        @central.audio_begin(n)
        i = 0
        while i < n
          @central.audio_chunk(ulaw.byteslice(i, AUDIO_CHUNK))
          i += AUDIO_CHUNK
        end
        @central.audio_play
        sleep_ms((n / 8) + AUDIO_TAIL_MS + AUDIO_MARGIN_MS)
        limit = @central.audio_done_timeout_ms(n)
        waited = 0
        until @central.audio_done?
          raise TimeoutError, "<audio_done> timeout" if waited >= limit
          sleep_ms AUDIO_POLL_MS
          waited += AUDIO_POLL_MS
        end
        nil
      end

      # Synthesizes text with the voice, sends the subtitle and plays the audio. Returns an OK line with the byte count, or an NG line when synthesis failed.
      # Raises ArgumentError when there is no voice.
      #: (String text, ?gain: Float?, ?rate: Integer?) -> String
      def say(text, gain: nil, rate: nil)
        v = voice
        @log.call("[checkpoint] synth_start")
        ulaw = @engine.unlocked { v.synthesize(text, gain, rate) }
        @log.call("[checkpoint] synth_done bytes=#{ulaw ? ulaw.bytesize : 0}")
        @central.raw_send(Stackchan::AI::FrameText.build(face_index: nil, text: text))
        @log.call("[checkpoint] subtitle_write_done")
        speak_audio(ulaw) if ulaw
        record(:say, last_say: text)
        return "NG say: synthesis failed or timed out" unless ulaw
        "OK say bytes=#{ulaw.bytesize}"
      end

      # Asks the voice for a reply to text, runs the reply handlers and speaks the reply (or the fallback audio when there is none). Returns the reply or nil.
      #: (String text, ?speak: bool) -> String?
      def chat(text, speak: true)
        v = voice
        heard = @state.dup
        reply = @engine.unlocked { v.respond(text, heard) }
        record(:chat, last_heard: text)
        if reply
          @engine.reply_handlers.each { |h| h.call(self, reply) }
          say(reply) if speak
        elsif speak && @fallback_audio
          speak_audio(@fallback_audio)
        end
        reply
      end

      # Calls a method on the robot's dRuby front and returns its reply.
      # The arguments are forwarded to whichever front method msg names and the reply is that method's return value (reply lines, touch zones, a bool, an Integer or an app handler's value), so both stay untyped.
      #: (String | Symbol msg, *untyped args) -> untyped
      def remote(msg, *args)
        lines = @central.call_front(msg.to_sym, args)
        record(:remote)
        lines
      end

      # Synthesizes phrase and keeps it as the fallback audio. Returns nil when there is no voice.
      #: (String phrase) -> String?
      def prime(phrase)
        return nil unless @voice
        @fallback_audio = @voice.synthesize(phrase)
      end

      private

      # Returns the voice, raising ArgumentError when none was given.
      #: () -> _Voice
      def voice
        raise ArgumentError, "no voice: say and chat need synthesize and respond" unless @voice
        @voice
      end

      # Stores the action name as last_action and merges extras into the state.
      #: (Symbol action, ?state_update extras) -> void
      def record(action, extras = {})
        @state[:last_action] = action.to_s
        extras.each { |k, v| @state[k] = v }
      end
    end
  end
end
