module StackChan
  class Robot
    # The dRuby front exposed to the central. Frame commands go through the Dispatcher; app remote handlers are defined as methods.
    class Remote
      BUILT_INS = [:command, :servo, :led, :face, :text, :torque, :read_pos, :stack_free,
                   :selftest, :touches, :audio_begin, :audio_chunk, :audio_play, :audio_done,
                   :servo_health]

      TOUCH_QUEUE_CAP = 16
      SILENCE_TAIL = ("\x00" * 3200)

      # An Array that collects written reply lines; stands in for the dispatcher's stdout.
      # @rbs inherits Array[String]
      class Lines < Array
        # Appends s.
        #: (String s) -> Array[String]
        def write(s)
          push(s)
        end
      end

      # @rbs @dispatcher: Dispatcher
      # @rbs @speaker: untyped
      # @rbs @head: Head?
      # @rbs @touch_queue: Array[Integer]
      # @rbs @audio_buf: String
      # @rbs @audio_pending: bool
      # @rbs @audio_done: bool

      attr_reader :exposed #: Array[Symbol]

      # Stores the collaborators and defines one method per app remote handler.
      #: (Dispatcher dispatcher, ?remote_handlers: Hash[Symbol, ^(Handle, *untyped) -> untyped], ?speaker: untyped, ?head: Head?) -> void
      def initialize(dispatcher, remote_handlers: {}, speaker: nil, head: nil)
        @dispatcher   = dispatcher
        @exposed      = BUILT_INS + remote_handlers.keys
        @speaker      = speaker
        @head         = head
        @touch_queue  = []
        @audio_buf    = String.new
        @audio_pending = false
        @audio_done   = false
        names = remote_handlers.keys
        i = 0
        while i < names.size
          define_handler(names[i], remote_handlers[names[i]])
          i += 1
        end
      end

      # Converts the frame Hash to string pairs, dispatches it and returns the reply lines (first line ".\n" or "?\n", then optional detail).
      #: (Hash[untyped, untyped] frame) -> Lines
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

      # Dispatches a face frame with index id.
      #: (untyped id) -> Lines
      def face(id)
        command({ "F" => id })
      end

      # Dispatches a subtitle frame.
      #: (String s) -> Lines
      def text(s)
        command({ "text" => s })
      end

      # Dispatches torque on when on is true or "on", otherwise off.
      #: (untyped on) -> Lines
      def torque(on)
        command({ "torque" => (on == true || on.to_s == "on") ? "on" : "off" })
      end

      # Dispatches a position read.
      #: () -> Lines
      def read_pos
        command({ "read" => "pos" })
      end

      # Returns a <stack_free:N> line with the stack high-water mark, or unknown when the VM cannot report it.
      #: () -> Lines
      def stack_free
        free = Machine.respond_to?(:stack_high_water_mark) ? Machine.stack_high_water_mark : "unknown"
        lines = Lines.new
        lines.write("<stack_free:#{free}>\n")
        lines
      end

      # Dispatches the servo selftest.
      #: () -> Lines
      def selftest
        command({ "selftest" => "run" })
      end

      # Queues a touch zone, dropping the oldest beyond 16.
      #: (Integer zone) -> Array[Integer]?
      def push_touch(zone)
        @touch_queue.push(zone)
        @touch_queue.shift while @touch_queue.size > TOUCH_QUEUE_CAP
      end

      # Returns the queued touch zones and empties the queue.
      #: () -> Array[Integer]
      def touches
        zones = @touch_queue
        @touch_queue = []
        zones
      end

      # Starts a new audio upload of n bytes, discarding any previous buffer. Returns true.
      #: (Integer n) -> bool
      def audio_begin(n)
        @audio_buf = String.new
        @audio_pending = false
        @audio_done = false
        true
      end

      # Appends bytes to the audio buffer and returns the buffered size.
      #: (String bytes) -> Integer
      def audio_chunk(bytes)
        @audio_buf << bytes
        @audio_buf.bytesize
      end

      # Marks the buffered audio for playback by perform_audio_play. Returns true.
      #: () -> bool
      def audio_play
        @audio_pending = true
        true
      end

      # Returns true once the reserved audio has been played.
      #: () -> bool
      def audio_done
        @audio_done
      end

      # Returns a line with each servo's last read error and status, or "?\n" when there is no head.
      #: () -> Lines
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

      # Plays the buffered audio on the speaker if playback was reserved, then marks it done. Returns nil when nothing was reserved.
      #: () -> bool?
      def perform_audio_play
        return unless @audio_pending
        @audio_pending = false
        if @speaker && @audio_buf.bytesize > 0
          @speaker.play_ulaw(@audio_buf)
          @speaker.i2s.write(SILENCE_TAIL)
        end
        @audio_done = true
      end

      private

      # Defines a singleton method name that calls handler with the robot handle and the arguments; skips names already defined.
      #: (Symbol name, ^(Handle, *untyped) -> untyped handler) -> void
      def define_handler(name, handler)
        return if respond_to?(name, true)
        define_singleton_method(name) { |*args| handler.call(@dispatcher.robot_handle, *args) }
      end

      # Returns err as a string, or "none" for nil.
      #: (untyped err) -> String
      def err_label(err)
        err.nil? ? "none" : err.to_s
      end

      # Returns status as a string, or "unknown" for nil.
      #: (untyped status) -> String
      def status_label(status)
        status.nil? ? "unknown" : status.to_s
      end
    end
  end
end
