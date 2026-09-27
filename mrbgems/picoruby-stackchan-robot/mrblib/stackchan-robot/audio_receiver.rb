module StackChan
  class Robot
    class AudioReceiver
      SILENCE_TAIL = ("\x00" * 3200)

      DRAIN_STEP_MS = 50

      def initialize(speaker:, parser:, notify:, drain:, pump:)
        @speaker = speaker
        @parser  = parser
        @notify  = notify
        @drain   = drain
        @pump    = pump
      end

      def consume(rx_data)
        @parser.feed(rx_data).each do |frame|
          if frame.key?("A")
            n = frame["A"].to_i
            next if n <= 0
            @notify.call("<A:ready>\n")
            ulaw = wait_and_drain(receive_t_ms(n))
            play(ulaw) if @speaker
            return true
          else
            yield frame
          end
        end
        false
      end

      private

      def receive_t_ms(n)
        (n * 1000 / 8000) + 3000
      end

      def wait_and_drain(t)
        buf = ""
        waited = 0
        while waited < t
          step = t - waited
          step = DRAIN_STEP_MS if step > DRAIN_STEP_MS
          Machine.delay_ms(step)
          waited += step
          @pump.call
          while (chunk = @drain.call)
            buf << chunk
          end
        end
        buf
      end

      def play(ulaw)
        return if ulaw.bytesize == 0
        @speaker.play_ulaw(ulaw)
        @speaker.i2s.write(SILENCE_TAIL)
      end
    end
  end
end
