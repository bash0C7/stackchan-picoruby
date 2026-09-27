module StackChan
  class Robot
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

      attr_reader :current_face

      def initialize(display:, led:, stdout: $stdout, head: nil)
        @display = display
        @led     = led
        @stdout  = stdout
        @head    = head
        neutral   = Face.new
        smile     = Face.new(mouth: 8)
        joy       = Face.new(mouth: 18)
        surprised = Face.new(mouth: :open)
        sad       = Face.new(mouth: -8)
        angry     = Face.new(brows: :angry)
        closed    = Face.new(eyes: :closed, mouth: :none)
        @face_table = {
          "0" => neutral,
          "1" => smile,
          "2" => joy,
          "3" => surprised,
          "4" => sad,
          "5" => angry,
        }.freeze
        @touch_table = {
          0 => [surprised, :both,  0, 60, 0],
          1 => [angry,     :right, 60, 0, 0],
          2 => [sad,       :left,  0, 0, 60],
        }.freeze
        @neutral_face = neutral
        @closed_face  = closed
        @current_face = neutral
      end

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
        @stdout.write(ok ? ACK_FRAME : ERROR_FRAME)
        emit_servo_detail if ok && servo
      rescue => e
        puts "[application] dispatch error: #{e.class}: #{e.message}"
        @stdout.write(ERROR_FRAME)
      end

      def handle_to(frame, sink)
        saved = @stdout
        @stdout = sink
        handle(frame)
      ensure
        @stdout = saved
      end

      def react_to_touch(zone)
        face, side, r, g, b = @touch_table[zone]
        @current_face = face
        face.redraw(@display)
        @led.flash_side(side, r, g, b)
      end

      private

      def handle_face(frame)
        face = @face_table[frame["F"]]
        return false unless face
        @current_face = face
        face.redraw(@display)
        true
      end

      def handle_text(frame)
        text = frame["text"]
        return false unless text
        text = text[0, SUBTITLE_MAX_CHARS]
        @display.draw_rect(0, SUBTITLE_BAND_Y, 320, SUBTITLE_BAND_HEIGHT,
                           SUBTITLE_BG, fill: true)
        @display.draw_text(SUBTITLE_MARGIN_X, SUBTITLE_TEXT_Y, text,
                           font: SUBTITLE_FONT, fg: SUBTITLE_FG, bg: SUBTITLE_BG)
        true
      end

      def handle_torque(frame)
        case frame["torque"]
        when "on"
          @head.enable_torque(true) if @head
          @current_face = @neutral_face
          @neutral_face.redraw(@display)
          @stdout.write(ACK_FRAME)
        when "off"
          @head.enable_torque(false) if @head
          @current_face = @closed_face
          @closed_face.redraw(@display)
          @stdout.write(ACK_FRAME)
        else
          @stdout.write(ERROR_FRAME)
        end
      end

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

      def handle_head(frame)
        yaw_raw   = nil
        pitch_raw = nil

        if frame.key?("YL")
          mag = frame["YL"].to_i
          return false unless mag >= 0 && mag <= 100
          yaw_raw = Head::SERVO_YAW_ZERO - (mag * Head::YAW_RANGE_RAW / 100)
        elsif frame.key?("YR")
          mag = frame["YR"].to_i
          return false unless mag >= 0 && mag <= 100
          yaw_raw = Head::SERVO_YAW_ZERO + (mag * Head::YAW_RANGE_RAW / 100)
        end

        if frame.key?("PU")
          mag = frame["PU"].to_i
          return false unless mag >= 0 && mag <= 100
          pitch_raw = Head::SERVO_PITCH_ZERO + (mag * Head::PITCH_RANGE_RAW / 100)
        end

        return false unless yaw_raw || pitch_raw
        return true if @head.nil?
        @head.apply(
          yaw_raw:   yaw_raw,
          pitch_raw: pitch_raw,
          time_ms:   (frame["T"] || "0").to_i,
          velocity:  (frame["V"] || "0").to_i,
        )
        true
      end

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
