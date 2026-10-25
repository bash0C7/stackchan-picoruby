module StackChan
  class Robot
    # Executes one parsed frame against the display, LEDs and head and writes the ACK or error reply.
    class Dispatcher
      ERROR_FRAME = "?\n"
      ACK_FRAME   = ".\n"

      MODE_TABLE = {
        "s" => :solid,
        "b" => :blink,
        "p" => :breathing,
        "o" => :off,
      }.freeze

      SIDE_TABLE = {
        "L" => :left,
        "R" => :right,
        "B" => :both,
      }.freeze

      SUBTITLE_BAND_Y      = 200
      SUBTITLE_BAND_HEIGHT = 240 - SUBTITLE_BAND_Y
      SUBTITLE_FONT        = "go16"
      SUBTITLE_TEXT_Y      = 212
      SUBTITLE_MARGIN_X    = 4
      SUBTITLE_MAX_CHARS   = 19
      SUBTITLE_FG          = 0xFFFF
      SUBTITLE_BG          = 0x0000

      attr_reader :current_face #: Face
      attr_reader :robot_handle #: Handle

      # Requires :neutral and :closed in faces (raises ArgumentError otherwise) and creates the robot handle.
      #: (display: _Display, led: StackchanLed, ?stdout: _Writer, ?head: Head?, ?speaker: AW88298?, faces: Hash[Symbol, Face], face_index: Hash[String, Symbol], ?frame_handlers: Hash[String, frame_handler]) -> void
      def initialize(display:, led:, stdout: $stdout, head: nil, speaker: nil,
                     faces:, face_index:, frame_handlers: {})
        raise ArgumentError, "faces: :neutral missing" unless faces[:neutral]
        raise ArgumentError, "faces: :closed missing" unless faces[:closed]
        @display        = display
        @led            = led
        @stdout         = stdout
        @head           = head
        @faces          = faces
        @face_index     = face_index
        @frame_handlers = frame_handlers
        @current_face   = faces[:neutral]
        @robot_handle = Handle.new(dispatcher: self, display: display, led: led, head: head, speaker: speaker)
      end

      # Runs the frame (torque, selftest, read, or face/led/text/head/custom keys) and writes the reply to stdout.
      # Writes the error reply instead when a step fails or raises.
      #: (frame frame) -> void
      def handle(frame)
        return handle_torque(frame)   if frame.key?("torque")
        return handle_selftest(frame) if frame.key?("selftest")
        return handle_read_pos(frame)  if frame.key?("read")

        ok = true
        ok = handle_face(frame) && ok if frame.key?("F")
        ok = handle_led(frame)  && ok if frame.key?("L")
        ok = handle_text(frame) && ok if frame.key?("text")
        servo = frame.key?("YL") || frame.key?("YR") || frame.key?("PU")
        ok = handle_head(frame) && ok if servo
        ok = run_frame_handlers(frame) && ok
        @stdout.write(ok ? ACK_FRAME : ERROR_FRAME)
        emit_servo_detail if ok && servo
      rescue => e
        puts "[application] dispatch error: #{e.class}: #{e.message}"
        @stdout.write(ERROR_FRAME)
      end

      # Runs handle with sink as stdout for this call and restores the previous stdout.
      #: (frame frame, _Writer sink) -> void
      def handle_to(frame, sink)
        saved = @stdout
        @stdout = sink
        handle(frame)
      ensure
        @stdout = saved
      end

      # Makes the named face current and redraws it. Returns false for an unknown name.
      #: (Symbol name) -> bool
      def show_face(name)
        face = @faces[name]
        return false unless face
        @current_face = face
        face.redraw(@display)
        true
      end

      # Draws text, cut to the subtitle width, in the subtitle band. Returns false when text is nil.
      #: (String? text) -> bool
      def draw_subtitle(text)
        return false unless text
        text = text[0, SUBTITLE_MAX_CHARS]
        @display.draw_rect(0, SUBTITLE_BAND_Y, 320, SUBTITLE_BAND_HEIGHT,
                           SUBTITLE_BG, fill: true)
        @display.draw_text(SUBTITLE_MARGIN_X, SUBTITLE_TEXT_Y, text,
                           font: SUBTITLE_FONT, fg: SUBTITLE_FG, bg: SUBTITLE_BG)
        true
      end

      # Converts 0..100 positions to raw servo targets and applies them. Returns false when a value is out of range or none is given.
      # Returns true without moving when there is no head.
      #: (Integer? yaw_left, Integer? yaw_right, Integer? pitch_up, Integer time_ms, Integer velocity) -> bool
      def move_head(yaw_left, yaw_right, pitch_up, time_ms, velocity)
        yaw_raw   = nil
        pitch_raw = nil

        if yaw_left
          return false unless yaw_left >= 0 && yaw_left <= 100
          yaw_raw = Head::SERVO_YAW_ZERO - (yaw_left * Head::YAW_RANGE_RAW / 100)
        elsif yaw_right
          return false unless yaw_right >= 0 && yaw_right <= 100
          yaw_raw = Head::SERVO_YAW_ZERO + (yaw_right * Head::YAW_RANGE_RAW / 100)
        end

        if pitch_up
          return false unless pitch_up >= 0 && pitch_up <= 100
          pitch_raw = Head::SERVO_PITCH_ZERO + (pitch_up * Head::PITCH_RANGE_RAW / 100)
        end

        return false unless yaw_raw || pitch_raw
        return true if @head.nil?
        @head.apply(yaw_raw: yaw_raw, pitch_raw: pitch_raw, time_ms: time_ms, velocity: velocity)
        true
      end

      private

      # Shows the face mapped from the F value. Returns false when unmapped.
      #: (frame frame) -> bool
      def handle_face(frame)
        name = @face_index[frame["F"]]
        return false unless name
        show_face(name)
      end

      # Calls the registered handler of every frame key and returns false if any handler returned falsy.
      #: (frame frame) -> bool
      def run_frame_handlers(frame)
        ok = true
        keys = frame.keys
        i = 0
        while i < keys.size
          handler = @frame_handlers[keys[i]]
          ok = handler.call(@robot_handle, frame[keys[i]]) && ok if handler
          i += 1
        end
        ok
      end

      # Draws the text value as subtitle.
      #: (frame frame) -> bool
      def handle_text(frame)
        draw_subtitle(frame["text"])
      end

      # Switches servo torque on (neutral face) or off (closed face) and writes ACK; any other value writes the error reply.
      #: (frame frame) -> void
      def handle_torque(frame)
        case frame["torque"]
        when "on"
          @head.enable_torque(true) if @head
          show_face(:neutral)
          @stdout.write(ACK_FRAME)
        when "off"
          @head.enable_torque(false) if @head
          show_face(:closed)
          @stdout.write(ACK_FRAME)
        else
          @stdout.write(ERROR_FRAME)
        end
      end

      # Runs the head self test and writes ACK plus the servo detail. Writes the error reply for another value or without a head.
      #: (frame frame) -> void
      def handle_selftest(frame)
        unless frame["selftest"] == "run"
          @stdout.write(ERROR_FRAME)
          return
        end
        if @head.nil?
          @stdout.write(ERROR_FRAME)
          return
        end
        @head.selftest
        @stdout.write(ACK_FRAME)
        emit_servo_detail
      end

      # Writes ACK and the raw yaw and pitch positions. Writes the error reply for another value or without a head.
      #: (frame frame) -> void
      def handle_read_pos(frame)
        unless frame["read"] == "pos"
          @stdout.write(ERROR_FRAME)
          return
        end
        if @head.nil?
          @stdout.write(ERROR_FRAME)
          return
        end
        @stdout.write(ACK_FRAME)
        actual = @head.read_actual
        yaw_raw   = actual[:yaw]
        pitch_raw = actual[:pitch]
        yaw_part   = yaw_raw.nil?   ? "yaw_raw:unknown"   : "yaw_raw:#{yaw_raw}"
        pitch_part = pitch_raw.nil? ? "pitch_raw:unknown" : "pitch_raw:#{pitch_raw}"
        @stdout.write("<#{yaw_part},#{pitch_part}>\n")
      end

      # Applies mode M, side S and color R/G/B to the LEDs. Returns false for an unknown mode or side.
      #: (frame frame) -> bool
      def handle_led(frame)
        mode = MODE_TABLE[frame["M"]]
        return false unless mode
        side = SIDE_TABLE[frame["S"]]
        return false unless side
        r = (frame["R"] || "0").to_i
        g = (frame["G"] || "0").to_i
        b = (frame["B"] || "0").to_i
        @led.animate_side(side, r, g, b, mode)
        true
      end

      # Moves the head from the YL, YR, PU, T and V values.
      #: (frame frame) -> bool
      def handle_head(frame)
        move_head(
          frame.key?("YL") ? frame["YL"].to_i : nil,
          frame.key?("YR") ? frame["YR"].to_i : nil,
          frame.key?("PU") ? frame["PU"].to_i : nil,
          (frame["T"] || "0").to_i,
          (frame["V"] || "0").to_i
        )
      end

      # Writes the actual yaw and pitch as 0..100 values, or unknown when unreadable or without a head.
      #: () -> void
      def emit_servo_detail
        if @head.nil?
          @stdout.write("<YL_actual:unknown,PU_actual:unknown>\n")
          return
        end
        actual = @head.read_actual
        yaw_raw   = actual[:yaw]
        pitch_raw = actual[:pitch]

        yaw_part = if yaw_raw.nil?
          "YL_actual:unknown"
        else
          delta = yaw_raw - Head::SERVO_YAW_ZERO
          if delta >= 0
            mag = delta * 100 / Head::YAW_RANGE_RAW
            "YR_actual:#{mag}"
          else
            mag = (-delta) * 100 / Head::YAW_RANGE_RAW
            "YL_actual:#{mag}"
          end
        end

        pitch_part = if pitch_raw.nil?
          "PU_actual:unknown"
        else
          delta = pitch_raw - Head::SERVO_PITCH_ZERO
          mag = delta >= 0 ? (delta * 100 / Head::PITCH_RANGE_RAW) : 0
          "PU_actual:#{mag}"
        end

        @stdout.write("<#{yaw_part},#{pitch_part}>\n")
      end
    end
  end
end
