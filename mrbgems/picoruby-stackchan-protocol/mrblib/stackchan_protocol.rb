module StackchanProtocol
  module Face
    EYE_LEFT_CX  = 90
    EYE_LEFT_CY  = 104
    EYE_RIGHT_CX = 230
    EYE_RIGHT_CY = 104
    EYE_RX       = 16
    EYE_RY       = 16

    EYE_COLOR        = ILI9342::Color::WHITE
    MOUTH_COLOR      = ILI9342::Color::WHITE
    BACKGROUND_COLOR = ILI9342::Color::BLACK

    MOUTH_CX         = 160
    MOUTH_CY         = 146
    MOUTH_HALF_WIDTH = 45

    class Base
      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
      end

      def draw_mouth(display, delta_y)
        cx = MOUTH_CX
        cy = MOUTH_CY
        hw = MOUTH_HALF_WIDTH
        left_x   = cx - hw
        right_x  = cx + hw
        corner_y = cy - delta_y
        display.draw_line(left_x, corner_y, cx,      cy,       MOUTH_COLOR)
        display.draw_line(cx,     cy,       right_x, corner_y, MOUTH_COLOR)
      end

      def draw(display)
        display.fill(BACKGROUND_COLOR)
        draw_eyes(display)
        draw_mouth(display, self.class::DELTA_Y)
      end
    end

    class Neutral < Base
      DELTA_Y = 0
    end

    class Smile < Base
      DELTA_Y = 8
    end

    class Joy < Base
      DELTA_Y = 18
    end
  end

  class Dispatcher
    FACES = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
    }

    ERROR_BYTE = "?"

    def initialize(display:, stdin: $stdin, stdout: $stdout)
      @display = display
      @stdin   = stdin
      @stdout  = stdout
    end

    def handle_byte(byte)
      face_class = FACES[byte]
      if face_class
        face_class.new.draw(@display)
      else
        @stdout.write(ERROR_BYTE)
      end
    rescue StandardError
      @stdout.write(ERROR_BYTE)
    end
  end
end
