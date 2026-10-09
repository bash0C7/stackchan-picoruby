module StackChan
  class Robot
    class Remote
      BUILT_INS = [:command, :servo, :led, :face, :text, :torque, :read_pos, :stack_free,
                   :selftest, :touches, :audio_begin, :audio_chunk, :audio_play, :audio_done,
                   :servo_health]

      TOUCH_QUEUE_CAP = 16
      SILENCE_TAIL = ("\x00" * 3200)

      class Lines < Array
        def write(s)
          push(s)
        end
      end

      attr_reader :exposed

      def initialize(dispatcher, remote_handlers: {}, speaker: nil, head: nil)
        @dispatcher   = dispatcher
        @handlers     = remote_handlers
        @exposed      = BUILT_INS + remote_handlers.keys
        @speaker      = speaker
        @head         = head
        @touch_queue  = []
        @audio_buf    = String.new
        @audio_pending = false
        @audio_done   = false
      end

      def command(frame)
        pairs = {}
        keys = frame.keys
        i = 0
        while i < keys.size
          pairs[keys[i].to_s] = frame[keys[i]].to_s
          i += 1
        end
        lines = Lines.new
        @dispatcher.handle_to(pairs, lines)
        lines
      end
      alias servo command
      alias led command

      def face(id)
        command({ "F" => id })
      end

      def text(s)
        command({ "text" => s })
      end

      def torque(on)
        command({ "torque" => (on == true || on.to_s == "on") ? "on" : "off" })
      end

      def read_pos
        command({ "read" => "pos" })
      end

      def stack_free
        free = Machine.respond_to?(:stack_high_water_mark) ? Machine.stack_high_water_mark : "unknown"
        lines = Lines.new
        lines.write("<stack_free:#{free}>\n")
        lines
      end

      def selftest
        command({ "selftest" => "run" })
      end

      def push_touch(zone)
        @touch_queue.push(zone)
        @touch_queue.shift while @touch_queue.size > TOUCH_QUEUE_CAP
      end

      def touches
        zones = @touch_queue
        @touch_queue = []
        zones
      end

      def audio_begin(n)
        @audio_buf = String.new
        @audio_pending = false
        @audio_done = false
        true
      end

      def audio_chunk(bytes)
        @audio_buf << bytes
        @audio_buf.bytesize
      end

      def audio_play
        @audio_pending = true
        true
      end

      def audio_done
        @audio_done
      end

      def servo_health
        lines = Lines.new
        if @head.nil?
          lines.write("?\n")
          return lines
        end
        health = @head.read_health
        yaw_err, yaw_status = health[:yaw]
        pitch_err, pitch_status = health[:pitch]
        lines.write("<yaw_err:#{err_label(yaw_err)},yaw_status:#{status_label(yaw_status)}," \
                    "pitch_err:#{err_label(pitch_err)},pitch_status:#{status_label(pitch_status)}>\n")
        lines
      end

      def perform_audio_play
        return unless @audio_pending
        @audio_pending = false
        if @speaker && @audio_buf.bytesize > 0
          @speaker.play_ulaw(@audio_buf)
          @speaker.i2s.write(SILENCE_TAIL)
        end
        @audio_done = true
      end

      def method_missing(name, *args)
        handler = @handlers[name]
        raise NoMethodError, "undefined method '#{name}' for StackChan::Robot::Remote" unless handler
        handler.call(@dispatcher.robot_handle, *args)
      end

      private

      def err_label(err)
        err.nil? ? "none" : err.to_s
      end

      def status_label(status)
        status.nil? ? "unknown" : status.to_s
      end
    end
  end
end
