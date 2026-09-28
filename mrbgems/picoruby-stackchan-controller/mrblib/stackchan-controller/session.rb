module StackChan
  class Controller
    class Session
      READY_WAIT_MS = 1500
      AUDIO_CHUNK   = 180
      CHUNK_PACE_MS = 20

      attr_reader :state
      attr_accessor :fallback_audio

      def initialize(central:, engine:, voice: nil, log:)
        @central        = central
        @engine         = engine
        @voice          = voice
        @log            = log
        @state          = { last_face: nil, last_say: nil, last_heard: nil, last_action: nil }
        @fallback_audio = nil
      end

      def face(name)
        @central.send { |b| b.face(name.to_sym) }
        record(:face, last_face: name.to_s)
        nil
      end

      def led(side, color, mode: :solid)
        @central.send { |b| b.led(color, side: side, mode: mode) }
        record(:led)
        nil
      end

      def servo(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
        @central.send do |b|
          b.head(yaw_left: yaw_left, yaw_right: yaw_right, pitch_up: pitch_up, time_ms: time_ms, velocity: velocity)
        end
        record(:servo)
        @central.last_detail_frame
      end

      def torque(on)
        @central.send { |b| b.torque(on: on) }
        record(:torque)
        nil
      end

      def selftest
        @central.send { |b| b.selftest }
        record(:selftest)
        @central.last_detail_frame
      end

      def read_pos
        @central.send { |b| b.read_pos }
        parsed = Calibration.parse_raw_detail(@central.last_detail_frame.to_s)
        raise DeviceError, Calibration::UNKNOWN_POSITION if parsed[:yaw_raw].nil? || parsed[:pitch_raw].nil?
        parsed
      end

      def text(s, face: nil)
        index = face.is_a?(Symbol) ? Stackchan::BLE::FrameCodec::FACE_INDICES.fetch(face) : face
        @central.raw_send(Stackchan::AI::FrameText.build(face_index: index, text: s))
        nil
      end

      def speak_audio(ulaw)
        n = ulaw.bytesize
        @central.write_without_ack("<A:#{n}>\n")
        @log.call("[checkpoint] announce_done n=#{n}")
        sleep_ms READY_WAIT_MS
        i = 0
        chunk_count = 0
        while i < n
          @central.write_without_ack(ulaw.byteslice(i, AUDIO_CHUNK))
          i += AUDIO_CHUNK
          chunk_count += 1
          @log.call("[checkpoint] blast_progress i=#{i} n=#{n}") if chunk_count % 100 == 0
          sleep_ms CHUNK_PACE_MS
        end
        @log.call("[checkpoint] blast_done i=#{i} n=#{n}, entering await")
        @central.await_audio_done(n)
        nil
      end

      def say(text, gain: nil, rate: nil)
        v = voice
        @log.call("[checkpoint] synth_start")
        ulaw = @engine.unlocked { v.synthesize(text, gain, rate) }
        @log.call("[checkpoint] synth_done bytes=#{ulaw ? ulaw.bytesize : 0}")
        @central.write_without_ack(Stackchan::AI::FrameText.build(face_index: nil, text: text))
        @log.call("[checkpoint] subtitle_write_done")
        speak_audio(ulaw) if ulaw
        record(:say, last_say: text)
        return "NG say: synthesis failed or timed out" unless ulaw
        "OK say bytes=#{ulaw.bytesize}"
      end

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

      def remote(msg, *args)
        lines = @central.remote.send(msg.to_sym, *args)
        record(:remote)
        lines
      end

      def prime(phrase)
        return nil unless @voice
        @fallback_audio = @voice.synthesize(phrase)
      end

      private

      def voice
        raise ArgumentError, "no voice: say and chat need synthesize and respond" unless @voice
        @voice
      end

      def record(action, extras = {})
        @state[:last_action] = action.to_s
        extras.each { |k, v| @state[k] = v }
      end
    end
  end
end
